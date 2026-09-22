import 'package:boltmesh/core/ip.dart';
import 'package:boltmesh/features/vpn/data/wg_conf.dart';
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
