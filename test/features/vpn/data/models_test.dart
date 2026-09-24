import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
