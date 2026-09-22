import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/domain/failover_policy.dart';
import 'package:flutter_test/flutter_test.dart';

Region region(String id, List<DiscoveryServer> servers) =>
    Region(id: id, name: id, servers: servers);

DiscoveryServer server(String id, {int peers = 0}) => DiscoveryServer(
  id: id,
  name: id,
  endpoint: '203.0.113.1',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  wgPublicKey: 'K',
  activePeers: peers,
);

void main() {
  group('shouldEscalateToFailover', () {
    test('false before the heal threshold', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 1,
          autoFailoverAttempts: 0,
          pollFailures: 3,
        ),
        isFalse,
      );
    });

    test('true once heals are exhausted with poll failures', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 2,
          autoFailoverAttempts: 0,
          pollFailures: 1,
        ),
        isTrue,
      );
    });

    test('false with a reachable backend (no poll failures)', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 5,
          autoFailoverAttempts: 0,
          pollFailures: 0,
        ),
        isFalse,
      );
    });

    test('false once the failover budget is spent', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 9,
          autoFailoverAttempts: 3,
          pollFailures: 9,
        ),
        isFalse,
      );
    });
  });

  group('slow-track escalation without poll failures', () {
    final now = DateTime(2026, 9, 17, 12);
    final stale = now.subtract(const Duration(seconds: 31));
    final fresh = now.subtract(const Duration(seconds: 5));

    test('failover fires after one heal on a quiet backend', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 1,
          healThreshold: 1,
          autoFailoverAttempts: 0,
          pollFailures: 0,
          lastStatusAt: stale,
          now: now,
        ),
        isTrue,
      );
    });

    test('failover stays put when the backend just answered', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 9,
          autoFailoverAttempts: 0,
          pollFailures: 0,
          lastStatusAt: fresh,
          now: now,
        ),
        isFalse,
      );
    });

    test('slow-track disabled without a clock (legacy callers)', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 2,
          autoFailoverAttempts: 0,
          pollFailures: 0,
          lastStatusAt: stale,
        ),
        isFalse,
      );
    });
  });

  group('isBackendCorroborated', () {
    final now = DateTime(2026, 9, 17, 12);
    final stale = now.subtract(const Duration(seconds: 31));
    final fresh = now.subtract(const Duration(seconds: 5));

    test('true on a poll failure even with a fresh backend', () {
      expect(
        isBackendCorroborated(pollFailures: 1, lastStatusAt: fresh, now: now),
        isTrue,
      );
    });

    test('true on a quiet backend with zero poll failures', () {
      expect(
        isBackendCorroborated(pollFailures: 0, lastStatusAt: stale, now: now),
        isTrue,
      );
    });

    test('true when no poll ever succeeded', () {
      expect(isBackendCorroborated(pollFailures: 0, now: now), isTrue);
    });

    test('false when the backend just answered', () {
      expect(
        isBackendCorroborated(pollFailures: 0, lastStatusAt: fresh, now: now),
        isFalse,
      );
    });
  });

  group('pickFailoverTarget', () {
    test('prefers same region, lowest load, excludes current', () {
      final regions = [
        region('us', [server('dead'), server('b', peers: 5)]),
        region('eu', [server('c', peers: 1)]),
      ];
      final target = pickFailoverTarget(
        regions: regions,
        currentRegionId: 'us',
        currentServerId: 'dead',
      );
      expect(target?.serverId, 'b');
      expect(target?.regionId, isNull);
    });

    test('falls back to global when the region has no other capacity', () {
      final regions = [
        region('us', [server('dead')]),
        region('eu', [server('c', peers: 7), server('d', peers: 2)]),
      ];
      final target = pickFailoverTarget(
        regions: regions,
        currentRegionId: 'us',
        currentServerId: 'dead',
      );
      expect(target?.serverId, 'd');
    });

    test('unpinned picks global lowest load', () {
      final regions = [
        region('us', [server('a', peers: 9)]),
        region('eu', [server('b', peers: 3)]),
      ];
      final target = pickFailoverTarget(
        regions: regions,
        currentRegionId: null,
        currentServerId: 'a',
      );
      expect(target?.serverId, 'b');
    });

    test('null when no other server has capacity', () {
      final regions = [
        region('us', [server('dead')]),
        region('empty', []),
      ];
      expect(
        pickFailoverTarget(
          regions: regions,
          currentRegionId: 'us',
          currentServerId: 'dead',
        ),
        isNull,
      );
    });

    test('stayInRegion keeps same-region moves', () {
      final regions = [
        region('us', [server('dead'), server('b', peers: 5)]),
        region('eu', [server('c', peers: 1)]),
      ];
      final target = pickFailoverTarget(
        regions: regions,
        currentRegionId: 'us',
        currentServerId: 'dead',
        stayInRegion: true,
      );
      expect(target?.serverId, 'b');
    });

    test('stayInRegion blocks cross-region fallback', () {
      final regions = [
        region('us', [server('dead')]),
        region('eu', [server('c', peers: 7), server('d', peers: 2)]),
      ];
      expect(
        pickFailoverTarget(
          regions: regions,
          currentRegionId: 'us',
          currentServerId: 'dead',
          stayInRegion: true,
        ),
        isNull,
      );
    });

    test('stayInRegion without a region never moves', () {
      final regions = [
        region('us', [server('a', peers: 9)]),
        region('eu', [server('b', peers: 3)]),
      ];
      expect(
        pickFailoverTarget(
          regions: regions,
          currentRegionId: null,
          currentServerId: 'a',
          stayInRegion: true,
        ),
        isNull,
      );
    });
  });
}
