import 'package:boltmesh/core/ip.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/platform_info.dart';
import 'package:boltmesh/features/vpn/data/wg_conf.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeAddressCidr', () {
    test('ipv4 bare gets /32', () {
      expect(normalizeAddressCidr('10.8.0.5'), '10.8.0.5/32');
    });

    test('ipv4 with stale suffix is pinned to /32', () {
      expect(normalizeAddressCidr('10.8.0.5/24'), '10.8.0.5/32');
    });

    test('ipv6 bare gets /128', () {
      expect(normalizeAddressCidr('fd00::5'), 'fd00::5/128');
    });

    test('whitespace trimmed', () {
      expect(normalizeAddressCidr('  10.8.0.5  '), '10.8.0.5/32');
    });
  });

  group('formatEndpoint', () {
    test('ipv4 host', () {
      expect(formatEndpoint('203.0.113.10', 51820), '203.0.113.10:51820');
    });

    test('ipv6 literal is bracketed', () {
      expect(formatEndpoint('fd00::1', 51820), '[fd00::1]:51820');
    });

    test('hostname untouched', () {
      expect(formatEndpoint('vpn.example.com', 51820), 'vpn.example.com:51820');
    });

    test('already bracketed ipv6 not double wrapped', () {
      expect(formatEndpoint('[fd00::1]', 51820), '[fd00::1]:51820');
    });
  });

  group('buildWgQuickConfig', () {
    test('matches backend shape', () {
      final conf = buildWgQuickConfig(
        privateKey: 'PRIV',
        assignedIp: '10.8.0.5',
        serverPublicKey: 'SRV',
        endpointHost: '203.0.113.10',
        endpointPort: 51820,
        dns: '10.8.0.1',
        allowLocal: false,
      );
      expect(conf, contains('PrivateKey = PRIV'));
      expect(conf, contains('Address = 10.8.0.5/32'));
      expect(conf, contains('DNS = 10.8.0.1'));
      expect(conf, contains('PublicKey = SRV'));
      expect(conf, contains('Endpoint = 203.0.113.10:51820'));
      expect(conf, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
      expect(conf, contains('PersistentKeepalive = 25'));
    });

    test('split tunnel is the default', () {
      final conf = buildWgQuickConfig(
        privateKey: 'PRIV',
        assignedIp: '10.8.0.5',
        serverPublicKey: 'SRV',
        endpointHost: '203.0.113.10',
        endpointPort: 51820,
        dns: '10.8.0.1',
      );
      expect(conf, isNot(contains('AllowedIPs = 0.0.0.0/0, ::/0')));
      expect(conf, contains('10.8.0.5/32'));
      expect(conf, contains('10.8.0.1/32'));
    });

    test('ipv6 address + endpoint', () {
      final conf = buildWgQuickConfig(
        privateKey: 'PRIV',
        assignedIp: 'fd00::5',
        serverPublicKey: 'SRV',
        endpointHost: 'fd00::1',
        endpointPort: 51820,
        dns: 'fd00::1',
      );
      expect(conf, contains('Address = fd00::5/128'));
      expect(conf, contains('Endpoint = [fd00::1]:51820'));
    });

    test('the local listen port is omitted unless a transport needs it', () {
      // Native and AmneziaWG leave ListenPort alone so the kernel picks an
      // ephemeral port, exactly as before the stream rung existed.
      final conf = buildWgQuickConfig(
        privateKey: 'PRIV',
        assignedIp: '10.8.0.5',
        serverPublicKey: 'SRV',
        endpointHost: '203.0.113.10',
        endpointPort: 51820,
        dns: '10.8.0.1',
      );
      expect(conf, isNot(contains('ListenPort')));
    });

    test('the stream rung pins the local port the bridge delivers to', () {
      final conf = buildWgQuickConfig(
        privateKey: 'PRIV',
        assignedIp: '10.8.0.5',
        serverPublicKey: 'SRV',
        // The peer endpoint is the bridge's loopback address, not the node.
        endpointHost: '127.0.0.1',
        endpointPort: 51821,
        dns: '10.8.0.1',
        listenPort: 51820,
      );
      expect(conf, contains('ListenPort = 51820'));
      expect(conf, contains('Endpoint = 127.0.0.1:51821'));
      // And it stays in the [Interface] section, where wg-quick reads it.
      final interface = conf.split('\n[Peer]').first;
      expect(interface, contains('ListenPort = 51820'));
    });

    test('an out-of-range listen port is refused', () {
      // The daemon refuses it too, but failing here names the client's own
      // bug instead of surfacing as an opaque bad_config from the helper.
      for (final port in [0, -1, 70000]) {
        expect(
          () => buildWgQuickConfig(
            privateKey: 'PRIV',
            assignedIp: '10.8.0.5',
            serverPublicKey: 'SRV',
            endpointHost: '127.0.0.1',
            endpointPort: 51821,
            dns: '10.8.0.1',
            listenPort: port,
          ),
          throwsArgumentError,
          reason: 'port $port',
        );
      }
    });

    test('blank inputs throw', () {
      String build({
        String privateKey = 'PRIV',
        String assignedIp = '10.8.0.5',
        String serverPublicKey = 'SRV',
        String endpointHost = '203.0.113.10',
        String dns = '10.8.0.1',
      }) => buildWgQuickConfig(
        privateKey: privateKey,
        assignedIp: assignedIp,
        serverPublicKey: serverPublicKey,
        endpointHost: endpointHost,
        endpointPort: 51820,
        dns: dns,
      );
      expect(() => build(privateKey: '  '), throwsArgumentError);
      expect(() => build(assignedIp: ''), throwsArgumentError);
      expect(() => build(serverPublicKey: ''), throwsArgumentError);
      expect(() => build(endpointHost: ''), throwsArgumentError);
      expect(() => build(dns: ''), throwsArgumentError);
    });
  });

  group('config injection guards', () {
    // The config is line-oriented: a control character in any interpolated
    // value could close its line and inject an extra directive.
    String build({
      String privateKey = 'PRIV',
      String assignedIp = '10.8.0.5',
      String serverPublicKey = 'SRV',
      String endpointHost = '203.0.113.10',
      String dns = '10.8.0.1',
    }) => buildWgQuickConfig(
      privateKey: privateKey,
      assignedIp: assignedIp,
      serverPublicKey: serverPublicKey,
      endpointHost: endpointHost,
      endpointPort: 51820,
      dns: dns,
      allowLocal: false,
    );

    test('a newline in endpointHost cannot inject a peer', () {
      expect(
        () => build(
          endpointHost:
              'evil.example\n[Peer]\nPublicKey = AAAA\n'
              'AllowedIPs = 0.0.0.0/0',
        ),
        throwsArgumentError,
      );
    });

    test('control characters in either key are rejected', () {
      expect(
        () => build(privateKey: 'PRIV\nAddress = 1.2.3.4/32'),
        throwsArgumentError,
      );
      expect(
        () => build(serverPublicKey: 'SRV\nAddress = 1.2.3.4/32'),
        throwsArgumentError,
      );
    });

    test('a newline in assignedIp is rejected', () {
      expect(() => build(assignedIp: '10.8.0.5\n[Peer]'), throwsArgumentError);
    });

    test('newline-separated DNS is normalized, never interpolated raw', () {
      final conf = build(dns: '10.8.0.1\n1.1.1.1');
      expect(conf, contains('DNS = 10.8.0.1, 1.1.1.1'));
      expect(conf, isNot(contains('DNS = 10.8.0.1\n')));
      expect(conf, isNot(contains('1.1.1.1\n[Peer]')));
    });
  });

  group('allowedIPs split tunnel', () {
    // Test-only longest-prefix-match check over an AllowedIPs string:
    // an IP is "in the tunnel" when the longest covering CIDR wins, with
    // host routes (/32, /128) beating the broader complement ranges.
    bool inTunnel(String ip, String allowed) {
      int? bestPrefix;
      var routed = false;
      for (final cidr in allowed.split(',')) {
        final parts = cidr.trim().split('/');
        if (parts.length != 2) continue;
        final net = parts[0].trim();
        final prefix = int.tryParse(parts[1].trim());
        if (prefix == null) continue;
        if (ip.contains(':') != net.contains(':')) continue;
        if (_contains(net, prefix, ip) &&
            (bestPrefix == null || prefix > bestPrefix)) {
          bestPrefix = prefix;
          routed = true;
        }
      }
      return routed;
    }

    const overlay = '10.8.0.5';
    const dns = '10.8.0.1';
    late String split;
    setUp(() {
      split = allowedIPs(allowLocal: true, assignedIp: overlay, dns: dns);
    });

    test('strict mode is the full tunnel', () {
      expect(
        allowedIPs(allowLocal: false, assignedIp: overlay, dns: dns),
        '0.0.0.0/0, ::/0',
      );
    });

    test('public traffic stays in the tunnel', () {
      for (final ip in [
        '8.8.8.8',
        '1.1.1.1',
        '203.0.113.10',
        '11.0.0.1',
        '172.32.0.1',
        '192.167.1.1',
        '192.169.1.1',
      ]) {
        expect(inTunnel(ip, split), isTrue, reason: ip);
      }
      expect(inTunnel('2001:4860:4860::8888', split), isTrue);
      expect(inTunnel('2606:4700:4700::1111', split), isTrue);
    });

    test('RFC1918 + link-local + multicast stay on the LAN', () {
      for (final ip in [
        '10.0.0.1',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.0.1',
        '192.168.1.10',
        '169.254.10.20',
        '224.0.0.251',
        '239.255.255.250',
      ]) {
        expect(inTunnel(ip, split), isFalse, reason: ip);
      }
      for (final ip in ['fc00::1', 'fd12::1', 'fe80::1', 'ff02::1']) {
        expect(inTunnel(ip, split), isFalse, reason: ip);
      }
    });

    test('overlay IP and DNS win via host routes', () {
      expect(inTunnel(overlay, split), isTrue);
      expect(inTunnel(dns, split), isTrue);
      expect(split, contains('$overlay/32'));
      expect(split, contains('$dns/32'));
    });

    test('comma-separated DNS list each gets a host route', () {
      final multi = allowedIPs(
        allowLocal: true,
        assignedIp: overlay,
        dns: '10.8.0.1, 1.1.1.1',
      );
      expect(multi, contains('10.8.0.1/32'));
      expect(multi, contains('1.1.1.1/32'));
      expect(inTunnel('10.8.0.1', multi), isTrue);
    });

    test('ipv6 overlay and DNS get /128 host routes', () {
      final v6 = allowedIPs(
        allowLocal: true,
        assignedIp: 'fd00::5',
        dns: 'fd00::1',
      );
      expect(v6, contains('fd00::5/128'));
      expect(v6, contains('fd00::1/128'));
      expect(inTunnel('fd00::5', v6), isTrue);
      expect(inTunnel('fd00::1', v6), isTrue);
      expect(inTunnel('fd12::9', v6), isFalse);
    });

    test('malformed overlay or DNS fails closed', () {
      expect(
        () => allowedIPs(allowLocal: true, assignedIp: 'nope', dns: dns),
        throwsArgumentError,
      );
      expect(
        () => allowedIPs(allowLocal: true, assignedIp: overlay, dns: 'nope'),
        throwsArgumentError,
      );
    });
  });

  group('buildWgQuickConfig obfuscation', () {
    String buildConf({ObfuscationParams? obfuscation}) => buildWgQuickConfig(
      privateKey: 'PRIV',
      assignedIp: '10.8.0.5',
      serverPublicKey: 'SRV',
      endpointHost: '203.0.113.10',
      endpointPort: 51820,
      dns: '10.8.0.1',
      obfuscation: obfuscation,
    );

    test('obfuscation params ride the interface section', () {
      final conf = buildConf(
        obfuscation: const ObfuscationParams(
          jc: 3,
          jmin: 40,
          jmax: 70,
          s1: 15,
          s2: 17,
          s3: 10,
          s4: 5,
          h1: [115, 120],
          h2: [130, 130],
          h3: [150, 160],
          h4: [171, 171],
        ),
      );
      // The exact directive block, in the order the helper's validation and
      // the device's UAPI consume it, between DNS and the [Peer] section.
      expect(
        conf,
        contains(
          'DNS = 10.8.0.1\n'
          'Jc = 3\n'
          'Jmin = 40\n'
          'Jmax = 70\n'
          'S1 = 15\n'
          'S2 = 17\n'
          'S3 = 10\n'
          'S4 = 5\n'
          'H1 = 115-120\n'
          'H2 = 130-130\n'
          'H3 = 150-160\n'
          'H4 = 171-171\n'
          '\n'
          '[Peer]',
        ),
      );
    });

    test('null obfuscation builds the classic native config', () {
      final conf = buildConf();
      expect(conf, isNot(contains('Jc =')));
      expect(conf, isNot(contains('H1 =')));
      // The native layout is unchanged: no stray blank lines between DNS
      // and [Peer].
      expect(conf, contains('DNS = 10.8.0.1\n\n[Peer]'));
    });
  });

  group('Obfuscation', () {
    test('decodes the backend descriptor shape', () {
      final obf = Obfuscation.fromJson(const {
        'mode': 'awg',
        'params': {
          'jc': 3,
          'jmin': 40,
          'jmax': 70,
          's1': 15,
          's2': 17,
          's3': 10,
          's4': 5,
          'h1': [115, 120],
          'h2': [130, 130],
          'h3': [150, 160],
          'h4': [171, 171],
        },
      });
      expect(obf.isAwg, isTrue);
      expect(obf.params!.jc, 3);
      expect(obf.params!.h1, [115, 120]);
    });

    test('mode without a complete param set is not awg', () {
      // A half-descriptor must never reach a conf: both tunnel ends must
      // run identical parameters, and a partial set cannot handshake.
      expect(const Obfuscation(mode: 'awg').isAwg, isFalse);
      expect(
        Obfuscation.fromJson(const {
          'mode': 'awg',
          'params': {
            'jc': 3,
            'jmin': 40,
            'jmax': 70,
            's1': 15,
            's2': 17,
            's3': 10,
            // s4 missing
            'h1': [115, 120],
            'h2': [130, 130],
            'h3': [150, 160],
            'h4': [171, 171],
          },
        }).isAwg,
        isFalse,
      );
      // A reversed range is malformed, not usable.
      expect(
        Obfuscation.fromJson(const {
          'mode': 'awg',
          'params': {
            'jc': 3,
            'jmin': 40,
            'jmax': 70,
            's1': 15,
            's2': 17,
            's3': 10,
            's4': 5,
            'h1': [120, 115],
            'h2': [130, 130],
            'h3': [150, 160],
            'h4': [171, 171],
          },
        }).isAwg,
        isFalse,
      );
    });

    test('native descriptor decodes as not awg', () {
      expect(const Obfuscation().isAwg, isFalse);
      expect(Obfuscation.fromJson(const {'mode': ''}).isAwg, isFalse);
    });
  });

  group('awgDataPlaneSupported', () {
    test('linux, windows, and Android AWG backends', () {
      expect(awgDataPlaneSupported(platform: TargetPlatform.linux), isTrue);
      // Windows runs the device in-process over a Wintun adapter rather than through
      // the kernel WireGuard service, which has no concept of the obfuscation
      // directives. Same device and wire format as Linux; only the adapter and the
      // address/route/resolver plumbing differ.
      expect(awgDataPlaneSupported(platform: TargetPlatform.windows), isTrue);
      // Android uses the AmneziaWG Go engine over the app's VpnService TUN;
      // it does not require the privileged desktop helper.
      expect(awgDataPlaneSupported(platform: TargetPlatform.android), isTrue);
      expect(awgDataPlaneSupported(platform: TargetPlatform.macOS), isFalse);
      expect(
        awgDataPlaneSupported(platform: TargetPlatform.linux, web: true),
        isFalse,
      );
    });
  });

  group('streamTransportSupported', () {
    test('linux and windows helpers', () {
      expect(streamTransportSupported(platform: TargetPlatform.linux), isTrue);
      expect(
        streamTransportSupported(platform: TargetPlatform.windows),
        isTrue,
      );
      expect(
        streamTransportSupported(platform: TargetPlatform.android),
        isTrue,
      );
      expect(streamTransportSupported(platform: TargetPlatform.macOS), isFalse);
      expect(
        streamTransportSupported(platform: TargetPlatform.linux, web: true),
        isFalse,
      );
    });

    test('a stream-carried obfuscated region needs both capabilities', () {
      // The transport carries whatever the tunnel produces, so for an obfuscated
      // region the obfuscated data plane is a precondition for the stream rung:
      // offering the transport without it would start a tunnel whose inner format
      // the node cannot read. The two stay separate predicates because they are two
      // capabilities -- how the datagrams travel versus what they say -- so this
      // pins the relationship rather than the two platform tables.
      for (final platform in TargetPlatform.values) {
        if (streamTransportSupported(platform: platform) &&
            !awgDataPlaneSupported(platform: platform)) {
          fail(
            '$platform offers the stream transport without the obfuscated data '
            'plane, so an obfuscated region could be started on a rung that cannot '
            'carry it',
          );
        }
      }
    });
  });
}

/// Test-only CIDR membership (mirrors prod parsing, asserts behavior).
bool _contains(String net, int prefix, String ip) {
  final isV6 = ip.contains(':');
  final bits = isV6 ? 128 : 32;
  final parse = isV6 ? parseIpV6 : parseIpV4;
  final mask = prefix == 0
      ? BigInt.zero
      : ((BigInt.one << prefix) - BigInt.one) << (bits - prefix);
  return (parse(net) & mask) == (parse(ip) & mask);
}
