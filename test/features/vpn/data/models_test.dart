import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/vpn_harness.dart';

/// The canonical complete AmneziaWG parameter set, as a wire object.
final Map<String, Object?> _awgParams = awgObfuscationParamsJson();

void main() {
  group('DialParams.fromJson', () {
    test('parses backend shape, defaults missing server_name', () {
      final dial = DialParams.fromJson({
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
      });
      expect(dial.deviceId, 'dev-1');
      expect(dial.assignedIp, '10.8.0.5');
      expect(dial.serverId, 'srv-1');
      expect(dial.serverName, '');
      expect(dial.wgPort, 51820);
      // A payload with no rung list offers nothing, which is a state the ladder
      // reads and refuses — not a missing field to default away into an offer.
      expect(dial.transports, isEmpty);
      expect(dial.advertisedRungs, isEmpty);
      expect(dial.transportFor(TransportRung.native), isNull);
    });

    test('reads the advertised rung list in order, port per rung', () {
      final dial = DialParams.fromJson({
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
        'transports': [
          {'rung': 'native', 'port': 51820},
          {'rung': 'awg', 'port': 51821, 'params': _awgParams},
        ],
      });
      // The order is the cost order and the ladder walks it, so it is read as
      // sent rather than sorted client-side.
      expect(dial.advertisedRungs, [TransportRung.native, TransportRung.awg]);
      // Each rung carries its own port: the node runs a separate device per rung,
      // so dialling another rung's port puts a plaintext handshake at a device
      // that cannot read it.
      expect(dial.transportFor(TransportRung.native)!.port, 51820);
      expect(dial.transportFor(TransportRung.awg)!.port, 51821);
      expect(dial.transportFor(TransportRung.stream), isNull);
    });

    test('a rung this build cannot assemble is not offered', () {
      // The awg entry with no parameter set is a conf the client cannot build,
      // and a stream entry with no credential is a bridge it cannot start. Both
      // are indistinguishable on-device from a rung that was never advertised, so
      // both are absent from what the ladder reads.
      final incomplete = DialParams.fromJson({
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
        'transports': [
          {'rung': 'native', 'port': 51820},
          {'rung': 'awg', 'port': 51821},
          {
            'rung': 'stream',
            'port': 443,
            'credential': {
              'server': 'a.example:443',
              'server_name': 'a.example',
            },
          },
        ],
      });
      expect(incomplete.advertisedRungs, [TransportRung.native]);
      expect(incomplete.transportFor(TransportRung.awg), isNull);
      expect(incomplete.transportFor(TransportRung.stream), isNull);
      // The raw entries still decode, so a malformed one is a value to inspect
      // rather than a payload that failed to parse.
      expect(incomplete.transports, hasLength(3));
    });

    test('an unknown rung name is not offered, and does not break the list', () {
      // A rung the backend adds later must degrade to "not offered" rather than
      // be mistaken for one this build can start — and must not cost the rungs
      // around it.
      final dial = DialParams.fromJson({
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
        'transports': [
          {'rung': 'native', 'port': 51820},
          {'rung': 'quic', 'port': 443},
          {'rung': 'awg', 'port': 51821, 'params': _awgParams},
        ],
      });
      expect(dial.advertisedRungs, [TransportRung.native, TransportRung.awg]);
      expect(dial.transports[1].rung, isNull);
    });
  });

  group('DiscoveryServer.fromJson', () {
    test('applies defaults for optional fields', () {
      final s = DiscoveryServer.fromJson({
        'id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
      });
      expect(s.name, '');
      expect(s.wgDns, '');
      expect(s.wgPublicKey, isNull);
      expect(s.activePeers, 0);
    });

    test('falls back to public_ip when endpoint is null', () {
      final s = DiscoveryServer.fromJson({
        'id': 'srv-1',
        'endpoint': null,
        'public_ip': '203.0.113.10',
        'wg_port': 51820,
      });
      expect(s.endpoint, '203.0.113.10');
    });

    test('falls back to public_ip when endpoint is blank', () {
      final s = DiscoveryServer.fromJson({
        'id': 'srv-1',
        'endpoint': '  ',
        'public_ip': '203.0.113.10',
        'wg_port': 51820,
      });
      expect(s.endpoint, '203.0.113.10');
    });

    test('prefers endpoint over public_ip when both set', () {
      final s = DiscoveryServer.fromJson({
        'id': 'srv-1',
        'endpoint': 'node-1.example.com',
        'public_ip': '203.0.113.10',
        'wg_port': 51820,
      });
      expect(s.endpoint, 'node-1.example.com');
    });

    test('missing endpoint and public_ip defaults to empty', () {
      final s = DiscoveryServer.fromJson({'id': 'srv-1', 'wg_port': 51820});
      expect(s.endpoint, '');
    });
  });

  group('Region', () {
    test('hasCapacity reflects dialable servers', () {
      Region region(List<Map<String, dynamic>> servers) =>
          Region.fromJson({'id': 'r-1', 'name': 'Region', 'servers': servers});
      expect(
        region([
          {'id': 'srv-1', 'endpoint': '203.0.113.10', 'wg_port': 51820},
        ]).hasCapacity,
        isTrue,
      );
      expect(region([]).hasCapacity, isFalse);
    });

    test('missing servers defaults to empty', () {
      final r = Region.fromJson({'id': 'r-1', 'name': 'Region'});
      expect(r.servers, isEmpty);
      expect(r.countryCode, isNull);
    });
  });

  test('Env.apiBaseUrl has no trailing slash', () {
    expect(Env.apiBaseUrl.endsWith('/'), isFalse);
  });

  group('DeviceStatus.fromJson', () {
    test('parses suspended payload with tier snapshot', () {
      final st = DeviceStatus.fromJson({
        'device_id': 'dev-1',
        'status': 'suspended',
        'suspended_reason': 'subscription_lapsed',
        'tier': 'pro',
        'max_devices': 5,
        'active_devices': 2,
        'subscription_expires_at': '2026-01-01T00:00:00Z',
      });
      expect(st.isSuspended, isTrue);
      expect(st.suspendedReason, 'subscription_lapsed');
      expect(st.subscriptionExpiresAt?.year, 2026);
    });

    test('requires status and does not default it to active', () {
      expect(
        () => DeviceStatus.fromJson({'device_id': 'dev-1'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('defaults optional fields with an explicit active status', () {
      final st = DeviceStatus.fromJson({
        'device_id': 'dev-1',
        'status': 'active',
      });
      expect(st.isSuspended, isFalse);
      expect(st.tier, isNull);
      expect(st.activeDevices, 0);
      expect(st.subscriptionExpiresAt, isNull);
    });
  });

  group('ServerStatus.fromJson', () {
    test('an online node is the only healthy verdict', () {
      final st = ServerStatus.fromJson({
        'server_id': 'srv-1',
        'name': 'node-eu',
        'status': 'online',
        'active_peers': 6,
      });
      expect(st.serverId, 'srv-1');
      expect(st.name, 'node-eu');
      expect(st.status, ServerHealth.online);
      expect(st.isOnline, isTrue);
      expect(st.isUnhealthy, isFalse);
      expect(st.activePeers, 6);
    });

    test('every non-online status is a reason to move', () {
      // The backend enum is the source of truth, so the client mirrors it
      // rather than trusting a derived boolean the backend has to keep in
      // sync. Each member must read as unhealthy.
      for (final status in ServerHealth.values.where(
        (s) => s != ServerHealth.online,
      )) {
        final st = ServerStatus.fromJson({
          'server_id': 'srv-1',
          'status': status.wire,
        });
        expect(st.isUnhealthy, isTrue, reason: status.wire);
        expect(st.isOnline, isFalse, reason: status.wire);
      }
    });

    test('an unknown status stays unknown, never healthy or dead', () {
      // A status the backend adds later must not read as online, and must not
      // read as a confirmed-dead node either: unknown is the only safe state,
      // because the two other readings drive a server move.
      final st = ServerStatus.fromJson({
        'server_id': 'srv-1',
        'status': 'draining',
      });
      expect(st.status, isNull);
      expect(st.isOnline, isFalse);
      expect(st.isUnhealthy, isFalse);
    });

    test('an absent status is unknown too', () {
      final st = ServerStatus.fromJson({'server_id': 'srv-1'});
      expect(st.status, isNull);
      expect(st.isUnhealthy, isFalse);
    });

    test('requires the server id', () {
      expect(
        () => ServerStatus.fromJson({'status': 'online'}),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
