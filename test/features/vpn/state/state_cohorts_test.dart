// Cohort guard: every mutable field the controller resets belongs to exactly
// one cohort (see ConnectionController's "State cohorts" doc), and each cohort
// must actually be dropped when a session ends. Each test primes the cohort's
// state non-default, drives one canonical session-end event, and asserts it is
// back to default — the cheap check that catches a new field added without a
// matching reset site.

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef FakeStore = support.FakeDeviceStore;
typedef FakeKeys = support.FakeKeys;

class FakeTunnel extends support.FakeTunnel {
  FakeTunnel(List<String> events)
    : super(events: events, stageValue: VpnStage.disconnected);
}

ProviderContainer makeContainer({
  required FakeStore store,
  required FakeKeys keys,
  required VpnApi api,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(keys),
      vpnApiProvider.overrideWithValue(api),
      networkMonitorProvider.overrideWithValue(
        support.FakeNetworkMonitor(true),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

VpnApi connectApi(List<String> events) => VpnApi(
  recordingDio(events, (o) {
    if (o.path.endsWith('/connect')) return dialJson();
    return null;
  }),
);

Future<void> seedConnected(
  ProviderContainer container,
  FakeStore store,
  FakeTunnel tunnel,
) async {
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
}

/// Primes the three resettable private cohorts to non-default values.
void primeCohorts(ConnectionController ctl) {
  ctl.debugDeadEchoStrikes = 3;
  ctl.debugPollsSinceRotate = 5;
  ctl.debugColdWatchArmed = true;
}

/// Asserts every primed cohort is back to its default.
void expectCohortsDropped(ConnectionController ctl) {
  expect(ctl.debugDeadEchoStrikes, 0);
  expect(ctl.debugPollsSinceRotate, 0);
  expect(ctl.debugColdWatchArmed, isFalse);
}

void main() {
  test(
    'disconnect drops the tunnel, rotation, and cold-restore cohorts',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: connectApi(events),
      );
      final tunnel = FakeTunnel(events);
      await seedConnected(container, store, tunnel);
      addTearDown(tunnel.close);
      final ctl = container.read(connectionProvider.notifier);
      primeCohorts(ctl);

      await ctl.disconnect();

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expectCohortsDropped(ctl);
    },
  );

  test('reset drops the same cohorts', () async {
    final events = <String>[];
    final store = FakeStore();
    final container = makeContainer(
      store: store,
      keys: FakeKeys(const []),
      api: connectApi(events),
    );
    final tunnel = FakeTunnel(events);
    await seedConnected(container, store, tunnel);
    addTearDown(tunnel.close);
    final ctl = container.read(connectionProvider.notifier);
    primeCohorts(ctl);

    ctl.reset();

    expect(container.read(connectionProvider).phase, ConnPhase.idle);
    expectCohortsDropped(ctl);
  });

  test('a denied stage ends the session and drops the cohorts', () async {
    final events = <String>[];
    final store = FakeStore();
    final container = makeContainer(
      store: store,
      keys: FakeKeys(const []),
      api: connectApi(events),
    );
    final tunnel = FakeTunnel(events);
    await seedConnected(container, store, tunnel);
    addTearDown(tunnel.close);
    final ctl = container.read(connectionProvider.notifier);
    // A denied stage ends the session outright: both counters are dropped by
    // the handler under test.
    ctl.debugDeadEchoStrikes = 3;
    ctl.debugPollsSinceRotate = 5;

    tunnel.emit(VpnStage.denied);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(connectionProvider).phase, ConnPhase.error);
    expect(ctl.debugDeadEchoStrikes, 0);
    expect(ctl.debugPollsSinceRotate, 0);
  });
}
