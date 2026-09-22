import 'package:boltmesh/features/vpn/data/backend_health.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;

void main() {
  group('classifyBackendHealth', () {
    test('no OS link is unreachable regardless of the probe', () {
      expect(
        classifyBackendHealth(hasLink: false, apiReachable: true),
        BackendHealth.unreachable,
      );
      expect(
        classifyBackendHealth(hasLink: false, apiReachable: null),
        BackendHealth.unreachable,
      );
    });

    test('probe result maps through, null stays unknown', () {
      expect(
        classifyBackendHealth(hasLink: true, apiReachable: true),
        BackendHealth.reachable,
      );
      expect(
        classifyBackendHealth(hasLink: true, apiReachable: false),
        BackendHealth.unreachable,
      );
      expect(
        classifyBackendHealth(hasLink: true, apiReachable: null),
        BackendHealth.unknown,
      );
    });
  });

  group('backendHealthProvider', () {
    ProviderContainer makeContainer({
      required bool link,
      required bool? probe,
    }) {
      final container = ProviderContainer(
        overrides: [
          networkMonitorProvider.overrideWithValue(
            support.FakeNetworkMonitor(link),
          ),
          controlPlaneProbeProvider.overrideWithValue(
            support.FakeControlProbe(probe),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    // `read(future)` alone does not keep an autoDispose provider alive:
    // hold a subscription open while awaiting the first emission.
    Future<BackendHealth> firstValue(ProviderContainer container) {
      final sub = container.listen(backendHealthProvider, (_, _) {});
      addTearDown(sub.close);
      return container.read(backendHealthProvider.future);
    }

    test('unreachable probe yields unreachable first', () async {
      final container = makeContainer(link: true, probe: false);
      await expectLater(
        firstValue(container),
        completion(BackendHealth.unreachable),
      );
    });

    test('reachable probe yields reachable first', () async {
      final container = makeContainer(link: true, probe: true);
      await expectLater(
        firstValue(container),
        completion(BackendHealth.reachable),
      );
    });

    test('offline link yields unreachable without probing', () async {
      final container = makeContainer(link: false, probe: true);
      await expectLater(
        firstValue(container),
        completion(BackendHealth.unreachable),
      );
    });

    test('unknown probe fails open', () async {
      final container = makeContainer(link: true, probe: null);
      await expectLater(
        firstValue(container),
        completion(BackendHealth.unknown),
      );
    });
  });
}
