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
  // The policy functions take their thresholds as required arguments so the
  // tuned values in `ConnectionTuning` are the single source. These mirror
  // that class; a retune there is a retune in production.
  const healThreshold = 2;
  const maxFailovers = 3;
  const pollThreshold = 1;
  const quietFor = Duration(seconds: 15);

  group('shouldEscalateToFailover', () {
    test('false before the heal threshold', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 1,
          autoFailoverAttempts: 0,
          pollFailures: 3,
          controlPlaneReachable: true,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
          controlPlaneReachable: true,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
          controlPlaneReachable: true,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
          controlPlaneReachable: true,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
        ),
        isFalse,
      );
    });

    test('false when the control plane is not positively reachable', () {
      expect(
        shouldEscalateToFailover(
          autoHealAttempts: 2,
          autoFailoverAttempts: 0,
          pollFailures: 3,
          controlPlaneReachable: false,
          healThreshold: 1,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
        ),
        isFalse,
      );
    });
  });

  group('canAttemptAutoHeal', () {
    test('allows one restart per incident', () {
      expect(
        canAttemptAutoHeal(
          autoHealAttempts: 0,
          autoFailoverAttempts: 0,
          maxFailovers: maxFailovers,
          maxHealsAfterMoveBudget: 1,
        ),
        isTrue,
      );
      expect(
        canAttemptAutoHeal(
          autoHealAttempts: 1,
          autoFailoverAttempts: 0,
          maxFailovers: maxFailovers,
          maxHealsAfterMoveBudget: 1,
        ),
        isFalse,
      );
    });

    test('allows the bounded post-budget retry when configured', () {
      expect(
        canAttemptAutoHeal(
          autoHealAttempts: 0,
          autoFailoverAttempts: maxFailovers,
          maxFailovers: maxFailovers,
          maxHealsAfterMoveBudget: 1,
        ),
        isTrue,
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
          controlPlaneReachable: true,
          lastStatusAt: stale,
          now: now,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
          controlPlaneReachable: true,
          lastStatusAt: fresh,
          now: now,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
          controlPlaneReachable: true,
          lastStatusAt: stale,
          healThreshold: healThreshold,
          maxFailovers: maxFailovers,
          quietFor: quietFor,
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
        isBackendCorroborated(
          pollFailures: 1,
          lastStatusAt: fresh,
          now: now,
          pollThreshold: pollThreshold,
          quietFor: quietFor,
        ),
        isTrue,
      );
    });

    test('true on a quiet backend with zero poll failures', () {
      expect(
        isBackendCorroborated(
          pollFailures: 0,
          lastStatusAt: stale,
          now: now,
          pollThreshold: pollThreshold,
          quietFor: quietFor,
        ),
        isTrue,
      );
    });

    test('true when no poll ever succeeded', () {
      expect(
        isBackendCorroborated(
          pollFailures: 0,
          now: now,
          pollThreshold: pollThreshold,
          quietFor: quietFor,
        ),
        isTrue,
      );
    });

    test('false when the backend just answered', () {
      expect(
        isBackendCorroborated(
          pollFailures: 0,
          lastStatusAt: fresh,
          now: now,
          pollThreshold: pollThreshold,
          quietFor: quietFor,
        ),
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
      expect(target, 'b');
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
      expect(target, 'd');
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
      expect(target, 'b');
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

    test('a pinned region only biases the order', () {
      final regions = [
        region('us', [server('dead'), server('b', peers: 5)]),
        region('eu', [server('c', peers: 1)]),
      ];
      final target = pickFailoverTarget(
        regions: regions,
        currentRegionId: 'us',
        currentServerId: 'dead',
      );
      // The busier same-region sibling still wins over the emptier region:
      // a pin is a preference, not a hard constraint.
      expect(target, 'b');
    });

    test('a dead pinned region falls back across regions', () {
      final regions = [
        region('us', [server('dead')]),
        region('eu', [server('c', peers: 7), server('d', peers: 2)]),
      ];
      expect(
        pickFailoverTarget(
          regions: regions,
          currentRegionId: 'us',
          currentServerId: 'dead',
        ),
        'd',
      );
    });

    test('a null region (unpinned) picks the global lowest load', () {
      final regions = [
        region('us', [server('a', peers: 9)]),
        region('eu', [server('b', peers: 3)]),
      ];
      expect(
        pickFailoverTarget(
          regions: regions,
          currentRegionId: null,
          currentServerId: 'a',
        ),
        'b',
      );
    });
  });
}
