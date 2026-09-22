import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef FakeStore = support.FakeDeviceStore;
typedef FakeKeys = support.FakeKeys;

class FakeTunnel extends support.FakeTunnel {
  FakeTunnel(List<String> events) : super(events: events);
}

ProviderContainer makeContainer({
  required FakeStore store,
  required FakeKeys keys,
  required VpnApi api,
  required support.FakeNetworkMonitor monitor,
  bool gatewayAlive = true,
  bool controlReachable = true,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(keys),
      vpnApiProvider.overrideWithValue(api),
      networkMonitorProvider.overrideWithValue(monitor),
      gatewayProbeProvider.overrideWithValue(
        support.FakeGatewayProbe(gatewayAlive),
      ),
      controlPlaneProbeProvider.overrideWithValue(
        support.FakeControlProbe(controlReachable),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The monitor the [seedConnected] helper wired into the container, so tests
/// can push link transitions into it.
late support.FakeNetworkMonitor monitor;

Future<(ProviderContainer, support.FakeTunnel)> seedConnected(
  List<String> events,
  dynamic Function(RequestOptions options) respond, {
  bool link = true,
  bool gatewayAlive = true,
  bool controlReachable = true,
}) async {
  final store = FakeStore();
  final keys = FakeKeys(const []);
  final api = VpnApi(recordingDio(events, respond));
  final tunnel = FakeTunnel(events);
  monitor = support.FakeNetworkMonitor(link);
  addTearDown(monitor.close);
  final container = makeContainer(
    store: store,
    keys: keys,
    api: api,
    monitor: monitor,
    gatewayAlive: gatewayAlive,
    controlReachable: controlReachable,
  );
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  // Fresh handshake by default: nothing heals unless a test stales it.
  ctl.debugHandshakeReader = () async => DateTime.now();
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
  events.clear();
  return (container, tunnel);
}

void main() {
  test('link loss surfaces the no-network banner immediately', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });

    monitor.emit(false);
    await pumpEventQueue();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.healthNote, contains('Waiting for network'));
    // No tunnel churn and no backend call just for losing the link.
    expect(events, isEmpty);
  });

  test(
    'a returning link runs the catch-up without waiting for a tick',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      });

      monitor.emit(false);
      await pumpEventQueue();
      expect(
        container.read(connectionProvider).healthNote,
        contains('Waiting for network'),
      );

      events.clear();
      monitor.emit(true);
      await pumpEventQueue();

      // The catch-up cleared its own banner and polled the backend at once.
      final state = container.read(connectionProvider);
      expect(state.healthNote, isNull);
      expect(state.pollFailures, 0);
      expect(events, contains('GET:/vpn-devices/dev-1/status'));
    },
  );

  test('a returning link heals a stale tunnel', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      },
      // Total blackout after the link comes back: the legacy heal ladder.
      gatewayAlive: false,
      controlReachable: false,
    );
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugHandshakeReader = () async =>
        DateTime.now().subtract(const Duration(minutes: 5));

    monitor.emit(false);
    await pumpEventQueue();
    events.clear();

    monitor.emit(true);
    await pumpEventQueue();

    // The catch-up health tick healed offline on the cached config; the
    // following successful poll then clears the heal budget.
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
  });

  test('link transitions while not connected are ignored', () async {
    final events = <String>[];
    final m = support.FakeNetworkMonitor(false);
    addTearDown(m.close);
    final container = makeContainer(
      store: FakeStore(),
      keys: FakeKeys(const []),
      api: VpnApi(
        recordingDio(events, (o) => throw StateError('unexpected ${o.path}')),
      ),
      monitor: m,
    );
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    m.emit(false);
    m.emit(true);
    await pumpEventQueue();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.healthNote, isNull);
    expect(events, isEmpty);
  });
}
