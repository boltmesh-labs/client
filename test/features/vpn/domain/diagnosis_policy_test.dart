import 'package:boltmesh/core/ip.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/domain/diagnosis_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyFailure', () {
    test('no link pauses everything', () {
      expect(
        classifyFailure(
          hasNetwork: false,
          gatewayAlive: false,
          apiReachable: false,
        ),
        ConnectionFailureCause.noLocalNetwork,
      );
      // Link state wins over every other signal.
      expect(
        classifyFailure(
          hasNetwork: false,
          gatewayAlive: true,
          apiReachable: true,
        ),
        ConnectionFailureCause.noLocalNetwork,
      );
    });

    test('alive gateway suppresses recovery', () {
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: true,
          apiReachable: false,
        ),
        ConnectionFailureCause.transientFlap,
      );
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: true,
          apiReachable: null,
        ),
        ConnectionFailureCause.transientFlap,
      );
    });

    test('dead gateway with reachable api fast-tracks failover', () {
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: false,
          apiReachable: true,
        ),
        ConnectionFailureCause.tunnelPathDead,
      );
    });

    test('dead gateway with dead api heals locally', () {
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: false,
          apiReachable: false,
        ),
        ConnectionFailureCause.totalBlackout,
      );
    });

    test('unknown api probe falls back to local heal, never failover', () {
      // Null = errored: must not move servers alone.
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: false,
          apiReachable: null,
        ),
        ConnectionFailureCause.totalBlackout,
      );
    });

    test('skipped gateway probe never fast-tracks, even with the api up', () {
      // Null = probe skipped/errored: absence of evidence, not death. A
      // reachable control plane alone must not stop the tunnel.
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: null,
          apiReachable: true,
        ),
        ConnectionFailureCause.totalBlackout,
      );
      // Same when the control probe was unknown too.
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: null,
          apiReachable: null,
        ),
        ConnectionFailureCause.totalBlackout,
      );
    });

    test('hard-stale handshake fast-tracks when the api is reachable', () {
      // The echo is unprobeable, but a handshake that stayed dead past the
      // hard ceiling is positive path-dead evidence: a reachable control
      // plane then means the node path is dead, so skip the offline restart.
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: null,
          apiReachable: true,
          hardStalled: true,
        ),
        ConnectionFailureCause.tunnelPathDead,
      );
      // An alive echo still wins (a transient flap is not a dead path).
      expect(
        classifyFailure(
          hasNetwork: true,
          gatewayAlive: true,
          apiReachable: true,
          hardStalled: true,
        ),
        ConnectionFailureCause.transientFlap,
      );
    });

    test('hard-stale handshake without the api stays a local heal', () {
      // Control plane silent/unknown: the conservative same-server ladder.
      for (final api in <bool?>[false, null]) {
        expect(
          classifyFailure(
            hasNetwork: true,
            gatewayAlive: null,
            apiReachable: api,
            hardStalled: true,
          ),
          ConnectionFailureCause.totalBlackout,
        );
      }
    });
  });

  group('firstDnsProbeIp', () {
    test('prefers the overlay dns', () {
      expect(firstDnsProbeIp('10.8.0.1'), '10.8.0.1');
      expect(firstDnsProbeIp('10.8.0.1, 1.1.1.1'), '10.8.0.1');
      expect(firstDnsProbeIp('1.1.1.1, 10.8.0.1'), '10.8.0.1');
    });

    test('falls back to a pinned public resolver', () {
      // The shipped config uses public resolvers; every configured DNS
      // server is pinned in-tunnel with a /32 host route, so its echo
      // still proves the data path.
      expect(firstDnsProbeIp('9.9.9.9, 149.112.112.112'), '9.9.9.9');
      expect(firstDnsProbeIp('9.9.9.9/32'), '9.9.9.9');
    });

    test('skips loopback, empty and malformed', () {
      expect(firstDnsProbeIp('127.0.0.1'), isNull);
      expect(firstDnsProbeIp('::1'), isNull);
      expect(firstDnsProbeIp(''), isNull);
      expect(firstDnsProbeIp('not-an-ip'), isNull);
      expect(firstDnsProbeIp('10.0.0.256'), isNull);
    });
  });

  group('IP validation and classification', () {
    test('rejects malformed IPv6 forms', () {
      expect(isValidIpV6('1:2:3:4:5:6:7:'), isFalse);
      expect(isValidIpV6(':::'), isFalse);
      expect(isValidIpV6('192.0.2.1::'), isFalse);
    });

    test('classifies private and loopback IPv6 by value', () {
      expect(isPrivateUnicastIp('FC00:0:0:0:0:0:0:1'), isTrue);
      expect(isPrivateUnicastIp('FE80:0:0:0:0:0:0:1'), isTrue);
      expect(isLoopbackIp('0:0:0:0:0:0:0:1'), isTrue);
      expect(isPrivateUnicastIp('fc:not-an-address'), isFalse);
    });

    test('rejects invalid loopback and prefix tokens', () {
      expect(isLoopbackIp('127.example'), isFalse);
      expect(bareIp('10.0.0.1/not-a-prefix'), isNull);
      expect(bareIp('10.0.0.1/33'), isNull);
    });
  });

  group('isPrivateUnicastIp', () {
    test('rfc1918 ranges', () {
      expect(isPrivateUnicastIp('10.0.0.1'), isTrue);
      expect(isPrivateUnicastIp('172.16.0.1'), isTrue);
      expect(isPrivateUnicastIp('172.31.255.255'), isTrue);
      expect(isPrivateUnicastIp('192.168.1.1'), isTrue);
      expect(isPrivateUnicastIp('fd00::1'), isTrue);
    });

    test('public, loopback and link-local excluded', () {
      expect(isPrivateUnicastIp('8.8.8.8'), isFalse);
      expect(isPrivateUnicastIp('172.32.0.1'), isFalse);
      expect(isPrivateUnicastIp('172.15.255.255'), isFalse);
      expect(isPrivateUnicastIp('127.0.0.1'), isFalse);
      expect(isPrivateUnicastIp('169.254.1.1'), isFalse);
    });
  });

  test('buildDnsQuery emits a well-formed query', () {
    final q = buildDnsQuery();
    // Header: id + flags + QD=1, AN=NS=AR=0.
    expect(q.sublist(0, 12), [
      0x12,
      0x34,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);
    // Tail: root label + A/IN.
    expect(q.sublist(q.length - 5), [0x00, 0x00, 0x01, 0x00, 0x01]);
  });

  group('ControlPlaneProbe.healthUrl', () {
    test('strips /v1, keeps host', () {
      expect(
        ControlPlaneProbe.healthUrl('https://api.boltmesh.net/v1'),
        'https://api.boltmesh.net/health',
      );
      expect(
        ControlPlaneProbe.healthUrl('http://localhost:8000/v1/'),
        'http://localhost:8000/health',
      );
      expect(
        ControlPlaneProbe.healthUrl('https://api.boltmesh.net'),
        'https://api.boltmesh.net/health',
      );
    });
  });
}
