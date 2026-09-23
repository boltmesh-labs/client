import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
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

void main() {
  test('rotate probes before stopping the tunnel, then restarts', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/rotate-keys')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).rotateKeys();

    // Probe-first: the POST travels before any stop; the single stop is
    // the restart onto the rotated key.
    expect(events, [
      'POST:/vpn-devices/dev-1/rotate-keys',
      'tunnel:stop',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'NEW-PRIV');
    expect(await store.publicKey(), 'NEW-PUB');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(
      container.read(connectionProvider.notifier).debugPollsSinceRotate,
      0,
    );
  });

  test('failed rotate after tunnel stop surfaces error', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/rotate-keys')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).rotateKeys();

    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(state.message, contains('Tunnel stopped'));
    // Probe first, then one direct retry after the stop.
    expect(events, [
      'POST:/vpn-devices/dev-1/rotate-keys',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/rotate-keys',
    ]);
  });

  test('in-tunnel rotate succeeds without stopping first', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/rotate-keys')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container.read(connectionProvider.notifier).rotateKeys();

    expect(events, [
      'POST:/vpn-devices/dev-1/rotate-keys',
      'tunnel:stop',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'NEW-PRIV');
  });

  test('active poll stores the snapshot and stays connected', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.deviceStatus?.tier, 'pro');
    expect(state.deviceStatus?.isSuspended, isFalse);
    expect(state.lastStatusAt, isNotNull);
    expect(events, ['GET:/vpn-devices/dev-1/status']);
  });

  test('suspended poll auto-disconnects with the lapse reason', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return suspendedStatusJson();
        if (o.path.endsWith('/disconnect')) return {'disconnected_peers': 1};
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).pollStatusOnce();

    expect(events, [
      'GET:/vpn-devices/dev-1/status',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/disconnect',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('lapsed'));
    // Device profile is kept so the user can renew and reconnect.
    expect(await store.deviceId(), 'dev-1');
  });

  test('revoked device on poll stops and prompts reprovision', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw missingDevice(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).pollStatusOnce();

    expect(events, ['GET:/vpn-devices/dev-1/status', 'tunnel:stop']);
    expect(await store.deviceId(), isNull);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('reprovision'));
  });

  test('transient poll failure keeps the tunnel up', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).pollStatusOnce();

    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    expect(events, ['GET:/vpn-devices/dev-1/status']);
  });

  test('queued auto-rotate cannot resurrect a disconnected tunnel', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        if (o.path.endsWith('/rotate-keys')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = tunnel;
    await ctl.connect();
    events.clear();

    // Queue disconnect first, then auto-rotation. The rotation must observe
    // the post-disconnect phase after the mutex is released, not restart the
    // tunnel from the stale dial retained for reconnect.
    final release = await ctl.debugAcquireMutex('test-hold');
    final disconnect = ctl.disconnect();
    final rotate = ctl.rotateKeys(auto: true);
    release();
    await disconnect;
    await rotate;

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(events, ['tunnel:stop', 'POST:/vpn-devices/dev-1/disconnect']);
    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');

    // The early-return path must release the operation mutex as well; a
    // second disconnect would otherwise hang behind the skipped rotation.
    await ctl.disconnect();
  });

  test('auto-rotate fires once the poll counter hits the threshold', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        if (o.path.endsWith('/rotate-keys')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugPollsSinceRotate =
        Env.keyRotationPolls - 1;
    events.clear();

    await container.read(connectionProvider.notifier).pollStatusOnce();

    expect(await store.privateKey(), 'NEW-PRIV');
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    expect(
      container.read(connectionProvider.notifier).debugPollsSinceRotate,
      0,
    );
  });
}
