import 'dart:async';

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:dio/dio.dart';
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

/// Tunnel whose stop always throws (e.g. driver already torn down).
class ThrowingTunnel extends FakeTunnel {
  ThrowingTunnel(super.events);

  @override
  Future<void> stopVpn() async {
    events.add('tunnel:stop');
    throw StateError('tunnel already down');
  }
}

/// Tunnel whose stop never completes (wedged engine thread).
class HangingTunnel extends FakeTunnel {
  HangingTunnel(super.events);
  int stops = 0;

  @override
  Future<void> stopVpn() {
    stops++;
    return Completer<void>().future;
  }
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
  // The op mutex serializes connect/switch/disconnect. A secure-storage read
  // that throws mid-op must still release it, or every later op wedges.
  group('operation mutex liveness', () {
    test('a throwing key read still releases the switch mutex', () async {
      final events = <String>[];
      final store = FakeStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = FakeTunnel(events);
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);

      store.privateKeyHook = () => throw StateError('keychain locked');
      await ctl.switchServer(regionId: null, serverId: 'srv-2');
      store.privateKeyHook = null;

      // A leaked lock would make this hang; the timeout fails the test.
      final release = await ctl
          .debugAcquireMutex('probe')
          .timeout(const Duration(seconds: 1));
      release();
    });
  });

  test('a stage stream error is logged, not thrown', () async {
    final events = <String>[];
    final store = FakeStore();
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(
      store: store,
      keys: FakeKeys(const []),
      api: api,
    );
    await seedConnected(container, store, tunnel);
    addTearDown(tunnel.close);
    events.clear();

    // A broken platform channel must not become an unhandled async error nor
    // tear down the live session.
    tunnel.emitError(StateError('stage channel broken'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    expect(events, isEmpty);
  });

  group('local network access (split tunnel)', () {
    VpnApi configApi(List<String> events) => VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );

    Future<ProviderContainer> seedWithStore(
      List<String> events,
      FakeStore store,
    ) async {
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: configApi(events),
      );
      return container;
    }

    test('connect uses split-tunnel AllowedIPs by default', () async {
      final events = <String>[];
      final store = FakeStore();
      final container = await seedWithStore(events, store);
      final tunnel = FakeTunnel(events);
      await seedConnected(container, store, tunnel);

      expect(await store.allowLocal(), isTrue);
      expect(tunnel.configs, hasLength(1));
      final conf = tunnel.configs.single;
      expect(conf, isNot(contains('AllowedIPs = 0.0.0.0/0, ::/0')));
      // Overlay + DNS stay in the tunnel despite living in 10.x.
      expect(conf, contains('10.8.0.5/32'));
      expect(conf, contains('10.8.0.1/32'));
    });

    test('strict mode connects with full-tunnel AllowedIPs', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setAllowLocal(false);
      final container = await seedWithStore(events, store);
      final tunnel = FakeTunnel(events);
      await seedConnected(container, store, tunnel);

      expect(tunnel.configs.single, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
    });

    test('toggling while connected restarts the tunnel offline', () async {
      final events = <String>[];
      final store = FakeStore();
      final container = await seedWithStore(events, store);
      final tunnel = FakeTunnel(events);
      await seedConnected(container, store, tunnel);
      events.clear();
      tunnel.configs.clear();

      await container.read(connectionProvider.notifier).setAllowLocal(false);

      expect(await store.allowLocal(), isFalse);
      // Offline restart: tunnel bounce, no control-plane POST.
      expect(events, ['tunnel:stop', 'tunnel:start']);
      expect(tunnel.configs.single, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
      expect(container.read(connectionProvider).phase, ConnPhase.connected);

      events.clear();
      tunnel.configs.clear();
      await container.read(connectionProvider.notifier).setAllowLocal(true);

      expect(events, ['tunnel:stop', 'tunnel:start']);
      expect(
        tunnel.configs.single,
        isNot(contains('AllowedIPs = 0.0.0.0/0, ::/0')),
      );
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
    });

    test('toggling while idle only persists', () async {
      final events = <String>[];
      final store = FakeStore();
      final container = await seedWithStore(events, store);

      await container.read(connectionProvider.notifier).setAllowLocal(false);

      expect(await store.allowLocal(), isFalse);
      expect(events, isEmpty);
      expect(await container.read(allowLocalProvider.future), isFalse);
    });
  });

  test('switch probes before stopping the tunnel', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) {
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // Probe-first: the POST travels before any stop; the single stop is
    // the restart onto the new server.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
    expect(await store.privateKey(), 'NEW-PRIV');
  });

  test('failed switch after tunnel stop surfaces error', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');
    final state = container.read(connectionProvider);
    // The fallback path already stopped the tunnel, so claiming
    // `connected` on the old server would lie: surface `error` and let
    // Connect reconcile via config/connect.
    expect(state.phase, ConnPhase.error);
    expect(state.message, contains('Tunnel stopped'));
    expect(state.dial?.serverId, 'srv-1');
    // Probe first, then one direct retry after the stop; no restart after
    // a failed POST.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/switch',
    ]);
  });

  test('idle switch transport failure keeps error without stopping', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/switch')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
      events,
    );

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // No tunnel is running while idle: a single direct attempt, no stop.
    expect(events, ['POST:/vpn-devices/dev-1/switch']);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(await store.privateKey(), 'OLD-PRIV');
  });

  test('switch to the current server makes no API call', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    // An explicit pin on the live server short-circuits before any key
    // generation or API call (the empty key queue below would throw).
    container
        .read(connectionProvider.notifier)
        .selectTarget(regionId: null, serverId: 'srv-1');
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-1');

    expect(events, isEmpty);
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test('switch to the current region makes no API call', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    // Simulate a quick-connect to region r-1, then re-select it.
    container
        .read(connectionProvider.notifier)
        .selectTarget(regionId: 'r-1', serverId: null);
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: 'r-1', serverId: null);

    expect(events, isEmpty);
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test('fresh connect stays unpinned (Auto)', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);

    // No selection was ever made: Auto stays unpinned (nothing persisted
    // either) while the dial still identifies the live server.
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.regionId, isNull);
    expect(state.serverId, isNull);
    expect(state.explicitTarget, isFalse);
    final saved = await store.lastTarget();
    expect(saved.regionId, isNull);
    expect(saved.serverId, isNull);
    expect(saved.explicitTarget, isFalse);
  });

  test('no-device switch to a region drops a stale server pin', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('KP1-PRIV', 'KP1-PUB')]);
    Map<dynamic, dynamic>? provisionBody;
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path == '/vpn-devices') {
          provisionBody = o.data as Map<dynamic, dynamic>;
          return dialJson(serverId: 'srv-r2', serverName: 'r2-server');
        }
        if (o.path.endsWith('/config')) {
          return dialJson(serverId: 'srv-r2', serverName: 'r2-server');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    // Stale pin: server s-1 selected earlier, now Quick Connect to r-2.
    ctl.selectTarget(regionId: null, serverId: 's-1');

    await ctl.switchServer(regionId: 'r-2', serverId: null);

    // The provision POST must carry only the new region, never the stale
    // server (previously leaked via selectTarget keep-semantics plus the
    // `?? state` fallback in _provision).
    expect(provisionBody, isNotNull);
    expect(provisionBody!['region_id'], 'r-2');
    expect(provisionBody!.containsKey('server_id'), isFalse);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.regionId, 'r-2');
    expect(state.serverId, isNull);
  });

  test('provision retry reuses the same keypair and idempotency key', () async {
    final events = <String>[];
    final store = FakeStore();
    // Single keypair in the queue: regenerating on retry would throw.
    final keys = FakeKeys([const Keypair('KP1-PRIV', 'KP1-PUB')]);
    final idemKeys = <String?>[];
    final pubKeys = <String?>[];
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path == '/vpn-devices') {
          idemKeys.add(o.headers['Idempotency-Key'] as String?);
          pubKeys.add((o.data as Map)['public_key'] as String?);
          if (idemKeys.length == 1) throw networkTimeout(o);
          return dialJson();
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    // First attempt: POST reaches the timeout, device stays unbound but the
    // pending keypair + idempotency key are kept for the retry.
    await expectLater(ctl.ensureProvisioned(), throwsA(isA<DioException>()));
    expect(await store.deviceId(), isNull);
    expect(await store.publicKey(), 'KP1-PUB');
    expect(await store.provisionKey(), isNotNull);

    // Retry: same keypair, same Idempotency-Key, no fresh generate() call.
    await ctl.ensureProvisioned();

    expect(await store.deviceId(), 'dev-1');
    expect(await store.publicKey(), 'KP1-PUB');
    expect(await store.provisionKey(), isNull);
    expect(idemKeys, hasLength(2));
    expect(idemKeys[0], isNotNull);
    expect(idemKeys[1], idemKeys[0]);
    expect(pubKeys, ['KP1-PUB', 'KP1-PUB']);
    expect(container.read(connectionProvider).phase, ConnPhase.idle);
  });

  test('provision 409 replays once with the same key', () async {
    final events = <String>[];
    final store = FakeStore();
    // Single keypair in the queue: the replay must reuse it, not mint.
    final keys = FakeKeys([const Keypair('KP1-PRIV', 'KP1-PUB')]);
    final idemKeys = <String?>[];
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path == '/vpn-devices') {
          idemKeys.add(o.headers['Idempotency-Key'] as String?);
          if (idemKeys.length == 1) throw idempotencyConflict(o);
          return dialJson();
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    // No throw: the conflict is retried once internally with the same key.
    await ctl.ensureProvisioned();

    expect(await store.deviceId(), 'dev-1');
    expect(await store.publicKey(), 'KP1-PUB');
    expect(await store.provisionKey(), isNull);
    expect(idemKeys, hasLength(2));
    expect(idemKeys[1], idemKeys[0]);
    expect(container.read(connectionProvider).phase, ConnPhase.idle);
  });

  test('provision 409 twice surfaces the error', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('KP1-PRIV', 'KP1-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path == '/vpn-devices') throw idempotencyConflict(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    await expectLater(ctl.ensureProvisioned(), throwsA(isA<DioException>()));
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    // The key is kept so an explicit user retry replays the same pair.
    expect(await store.provisionKey(), isNotNull);
  });

  test('offline disconnect ends idle after API failure', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).disconnect();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('locally'));
    expect(state.lastStage, isNull);
    expect(events, ['tunnel:stop', 'POST:/vpn-devices/dev-1/disconnect']);
  });

  test('disconnect proceeds to idle when the tunnel stop throws', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = ThrowingTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).disconnect();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('Disconnected'));
    // Graceful attempt + one automated hard-kill retry, then the
    // control-plane release still runs.
    expect(events, [
      'tunnel:stop',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/disconnect',
    ]);
  });

  test('disconnect proceeds to idle when the tunnel stop hangs', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = HangingTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).disconnect();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('Disconnected'));
    // Graceful attempt timed out, automated hard-kill retry fired.
    expect(tunnel.stops, 2);
    expect(events, ['POST:/vpn-devices/dev-1/disconnect']);
  });

  test(
    'releaseDevice disconnects, revokes, and wipes the local identity',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys(const []);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/disconnect')) {
            return {'disconnected_peers': 1};
          }
          if (o.path == '/vpn-devices/dev-1') return null;
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await seedConnected(container, store, tunnel);
      events.clear();

      await container.read(connectionProvider.notifier).releaseDevice();

      // Disconnect releases the peer, then the hard delete frees the plan slot.
      expect(events, [
        'tunnel:stop',
        'POST:/vpn-devices/dev-1/disconnect',
        'DELETE:/vpn-devices/dev-1',
      ]);
      expect(await store.deviceId(), isNull);
      expect(await store.privateKey(), isNull);
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
    },
  );

  test('releaseDevice still wipes locally when revoke 404s', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        if (o.path == '/vpn-devices/dev-1') throw missingDevice(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).releaseDevice();

    // Already revoked server-side: local wipe still runs.
    expect(await store.deviceId(), isNull);
    expect(await store.privateKey(), isNull);
  });

  test('forgetDevice releases the device then resets local state', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        if (o.path == '/vpn-devices/dev-1') return null;
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await container.read(connectionProvider.notifier).forgetDevice();

    // Tunnel stops, the peer is released, the hard delete frees the plan
    // slot, then the UI resets.
    expect(events, [
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/disconnect',
      'DELETE:/vpn-devices/dev-1',
    ]);
    expect(await store.deviceId(), isNull);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, 'Ready');
  });

  test('releaseDevice holds the op mutex across the local wipe', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        if (o.path == '/vpn-devices/dev-1') return null;
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);

    final wipeReached = Completer<void>();
    final wipeGate = Completer<void>();
    store.clearDeviceHook = () async {
      wipeReached.complete();
      await wipeGate.future;
    };

    final release = container.read(connectionProvider.notifier).releaseDevice();
    await wipeReached.future;

    // The wipe is paused mid-release: the mutex must still be held, so a
    // concurrent op queues instead of interleaving with revoke/wipe.
    var acquired = false;
    final probe = container
        .read(connectionProvider.notifier)
        .debugAcquireMutex('probe')
        .then((unlock) {
          acquired = true;
          unlock();
        });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(acquired, isFalse);

    wipeGate.complete();
    await release;
    await probe;
    expect(acquired, isTrue);
    expect(await store.deviceId(), isNull);
  });

  test('failed connect bind keeps old keypair', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) throw peerless(o);
        if (o.path.endsWith('/connect')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    await ctl.connect();

    expect(await store.privateKey(), 'OLD-PRIV');
    expect(container.read(connectionProvider).phase, ConnPhase.error);
  });

  test(
    'missing device config surfaces reprovision without bind attempt',
    () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) throw missingDevice(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = FakeTunnel(events);

      await ctl.connect();

      // True 404 must not fall through to POST /connect: no key burned.
      expect(events, ['GET:/vpn-devices/dev-1/config']);
      expect(await store.deviceId(), isNull);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.error);
      expect(state.message, contains('Reprovision'));
    },
  );

  test('in-tunnel switch succeeds without stopping first', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) {
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // Zero-drop order: POST first, single stop only for the restart.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(await store.privateKey(), 'NEW-PRIV');
  });

  test('in-tunnel failure falls back to one direct retry', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    var switchCalls = 0;
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) {
          if (switchCalls++ == 0) throw networkTimeout(o);
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(await store.privateKey(), 'NEW-PRIV');
  });

  test('double transport failure reports unknown status', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/switch',
    ]);
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.message, contains('unknown'));
  });

  test('in-tunnel app error never retries or stops', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        // Generic app error (not already-bound): no retry, no stop, the
        // old tunnel keeps running. alreadyConnected has its own
        // reconnect recovery (see the already-bound tests below).
        if (o.path.endsWith('/switch')) throw idempotencyConflict(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, ['POST:/vpn-devices/dev-1/switch']);
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.message, contains('still on'));
  });

  test('peerless switch while idle binds a fresh peer on the target', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    // One key for the doomed switch POST, one for the fresh bind.
    final keys = FakeKeys([
      const Keypair('SWITCH-PRIV', 'SWITCH-PUB'),
      const Keypair('FRESH-PRIV', 'FRESH-PUB'),
    ]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/switch')) throw peerless(o);
        if (o.path.endsWith('/connect')) {
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    await ctl.switchServer(regionId: null, serverId: 'srv-2');

    // Idle switch attempts the POST before any stop; the peerless 404
    // then stops the stale tunnel and binds fresh on the target.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'FRESH-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
  });

  test('peerless switch while connected rebinds on the new target', () async {
    final events = <String>[];
    final store = FakeStore();
    // One key for the doomed switch POST, one for the fresh bind.
    final keys = FakeKeys([
      const Keypair('SWITCH-PRIV', 'SWITCH-PUB'),
      const Keypair('FRESH-PRIV', 'FRESH-PUB'),
    ]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/switch')) throw peerless(o);
        if (o.path.endsWith('/connect')) {
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // In-tunnel POST hits the peerless 404, so the recovery stops the
    // stale tunnel and binds fresh on the requested target.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'FRESH-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
  });

  List<Map<String, dynamic>> regionsWithSrv1() => [
    {
      'id': 'r-1',
      'name': 'Region One',
      'country_code': 'US',
      'servers': [
        {
          'id': 'srv-1',
          'name': 'one',
          'endpoint': '203.0.113.10',
          'wg_port': 51820,
          'wg_dns': '10.8.0.1',
          'active_peers': 3,
        },
      ],
    },
  ];

  test('already-bound region switch while idle loads config and pins parent region', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final keys = FakeKeys([const Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/switch')) throw alreadyConnected(o);
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/vpn-regions')) return regionsWithSrv1();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, keys: keys, api: api);
    container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
      events,
    );

    // Idle after restart: no dial, no pinned target — the skip-check can't
    // fire, so the POST 409s with SERVER_CONFLICT.
    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: 'r-1', serverId: null);

    // No tunnel is running while idle, so no stop precedes the POST.
    expect(events, [
      'POST:/vpn-devices/dev-1/switch',
      'GET:/vpn-devices/dev-1/config',
      'tunnel:start',
      'GET:/vpn-regions',
    ]);
    // The ephemeral switch key is discarded; the working key survives.
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.regionId, 'r-1');
    expect(state.serverId, isNull);
  });

  test(
    'already-bound region switch falls back to server pin when discovery fails',
    () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/switch')) throw alreadyConnected(o);
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/vpn-regions')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );

      await container
          .read(connectionProvider.notifier)
          .switchServer(regionId: 'r-1', serverId: null);

      expect(events, [
        'POST:/vpn-devices/dev-1/switch',
        'GET:/vpn-devices/dev-1/config',
        'tunnel:start',
        'GET:/vpn-regions',
      ]);
      expect(await store.privateKey(), 'OLD-PRIV');
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.regionId, isNull);
      expect(state.serverId, 'srv-1');
    },
  );

  test(
    'already-bound server switch while connected restarts on dial server',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys([const Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/switch')) throw alreadyConnected(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await seedConnected(container, store, tunnel);
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugForceThroughTunnel = true;
      // Desync the pin so the skip-check misses and the POST 409s, as after
      // a restart that lost the pinned target.
      ctl.selectTarget(regionId: 'r-9', serverId: null);
      events.clear();

      await ctl.switchServer(regionId: null, serverId: 'srv-1');

      // In-tunnel POST 409s immediately (no fallback stop first); the
      // recovery stops the live tunnel, then loads config and restarts.
      expect(events, [
        'POST:/vpn-devices/dev-1/switch',
        'tunnel:stop',
        'GET:/vpn-devices/dev-1/config',
        'tunnel:start',
      ]);
      expect(await store.privateKey(), 'OLD-PRIV');
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.regionId, isNull);
      expect(state.serverId, 'srv-1');
    },
  );

  group('quickConnect', () {
    Map<String, dynamic> regionJson(String id, String serverId, int peers) => {
      'id': id,
      'name': id,
      'country_code': 'US',
      'servers': [
        {
          'id': serverId,
          'name': serverId,
          'endpoint': '203.0.113.10',
          'wg_port': 51820,
          'wg_dns': '10.8.0.1',
          'active_peers': peers,
        },
      ],
    };

    test(
      'idle without region auto-picks lowest load and reuses its peer',
      () async {
        final events = <String>[];
        final store = FakeStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/vpn-regions')) {
              return [
                regionJson('r-heavy', 'srv-h', 10),
                regionJson('r-best', 'srv-b', 2),
              ];
            }
            // The device already holds a server-side peer in the best region
            // (the norm straight after provision): server truth must be
            // reused, never re-`connect`ed (the backend binds on a peerless
            // device only, so a blind bind would 409).
            if (o.path.endsWith('/config')) {
              return dialJson(serverId: 'srv-b', serverName: 'b');
            }
            throw StateError('unexpected ${o.path}');
          }),
        );
        final container = makeContainer(
          store: store,
          keys: FakeKeys([const Keypair('AUTO-PRIV', 'AUTO-PUB')]),
          api: api,
        );
        container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
          events,
        );

        await container.read(connectionProvider.notifier).quickConnect();

        // Auto re-picks fresh: discovery, then the live peer is started as-is
        // (no bind) and the state stays unpinned.
        expect(events, [
          'GET:/vpn-regions',
          'GET:/vpn-devices/dev-1/config',
          'tunnel:start',
        ]);
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-b');
        expect(state.regionId, isNull);
        expect(state.serverId, isNull);
        expect(state.explicitTarget, isFalse);
      },
    );

    test('idle auto switches a live peer in another region', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [
              regionJson('r-old', 'srv-old', 9),
              regionJson('r-best', 'srv-best', 1),
            ];
          }
          // The live peer sits in another region: move it one-shot instead
          // of binding a second peer (which the backend would reject).
          if (o.path.endsWith('/config')) {
            return dialJson(serverId: 'srv-old', serverName: 'old');
          }
          if (o.path.endsWith('/switch')) {
            return dialJson(serverId: 'srv-best', serverName: 'best');
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, [
        'GET:/vpn-regions',
        'GET:/vpn-devices/dev-1/config',
        'POST:/vpn-devices/dev-1/switch',
        // The switch restart defensively stops first (no-op from idle).
        'tunnel:stop',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-best');
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
    });

    test('idle auto binds a fresh peer when the device is peerless', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('FRESH-PRIV', 'FRESH-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-best', 'srv-b', 1)];
          }
          // Disconnected/GC'd device: server truth is "no active peer", so
          // the Auto path falls back to a one-shot bind on the best region.
          if (o.path.endsWith('/config')) throw peerless(o);
          if (o.path.endsWith('/connect')) {
            return dialJson(serverId: 'srv-b', serverName: 'b');
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, [
        'GET:/vpn-regions',
        'GET:/vpn-devices/dev-1/config',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-b');
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
    });

    test('fresh device provisions onto the best region one-shot', () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys([const Keypair('SEED-PRIV', 'SEED-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-2', 'srv-2', 1)];
          }
          if (o.path == '/vpn-devices') return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );
      // Fresh device: quickConnect provisions onto the best region
      // one-shot, staying unpinned (Auto).
      await container.read(connectionProvider.notifier).quickConnect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(container.read(connectionProvider).regionId, isNull);
      expect(container.read(connectionProvider).serverId, isNull);
    });

    test('no capacity surfaces error without dialing', () async {
      final events = <String>[];
      final store = FakeStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) return <dynamic>[];
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );

      await container.read(connectionProvider.notifier).quickConnect();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.error);
      expect(state.dial, isNull);
      expect(events, ['GET:/vpn-regions']);
    });

    test('idle with pinned server reuses it without discovery', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = FakeTunnel(events);
      ctl.selectTarget(regionId: null, serverId: 'srv-1');

      events.clear();
      await ctl.quickConnect();

      // Sticky: no discovery fetch, straight to config + tunnel start.
      expect(events, ['GET:/vpn-devices/dev-1/config', 'tunnel:start']);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.serverId, 'srv-1');
    });

    test('idle with pinned region reuses it without discovery', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = FakeTunnel(events);
      ctl.selectTarget(regionId: 'r-1', serverId: null);

      events.clear();
      await ctl.quickConnect();

      expect(events, ['GET:/vpn-devices/dev-1/config', 'tunnel:start']);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.regionId, 'r-1');
    });

    test('disconnect keeps pin, quickConnect redials same server', () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys(const []);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/disconnect')) {
            return {'disconnected_peers': 1};
          }
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-other', 'srv-other', 0)];
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await seedConnected(container, store, tunnel);
      // Simulate a server tap, then a graceful disconnect.
      container
          .read(connectionProvider.notifier)
          .selectTarget(regionId: null, serverId: 'srv-1');
      await container.read(connectionProvider.notifier).disconnect();
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(container.read(connectionProvider).serverId, 'srv-1');
      events.clear();

      await container.read(connectionProvider.notifier).quickConnect();

      // Same server, and no auto-pick discovery went out.
      expect(events, ['GET:/vpn-devices/dev-1/config', 'tunnel:start']);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
    });

    test('persisted target is reused by a fresh container', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastTarget(
        regionId: null,
        serverId: 'srv-1',
        explicitTarget: true,
      );
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, ['GET:/vpn-devices/dev-1/config', 'tunnel:start']);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.serverId, 'srv-1');
    });

    test('selectAuto clears a pin and persists it', () async {
      final store = FakeStore();
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: VpnApi(
          recordingDio(<String>[], (o) {
            throw StateError('unexpected ${o.path}');
          }),
        ),
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.selectTarget(regionId: null, serverId: 'srv-1');

      await ctl.selectAuto();

      final state = container.read(connectionProvider);
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
      // Awaited persist: a following quickConnect can't resurrect the pin.
      final saved = await store.lastTarget();
      expect(saved.regionId, isNull);
      expect(saved.serverId, isNull);
      expect(saved.explicitTarget, isFalse);
    });

    test('releaseDevice surfaces a failed identity wipe', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/disconnect')) return {'disconnected_peers': 1};
          if (o.method == 'DELETE') return <String, dynamic>{};
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      final ctl = container.read(connectionProvider.notifier);
      // The wipe and its single retry both fail: the release must report that
      // instead of pretending the old identity is gone.
      store.clearDeviceHook = () => throw StateError('keychain locked');

      await expectLater(ctl.releaseDevice(), throwsA(isA<StateError>()));
      // The failed wipe must still have released the op mutex.
      final release = await ctl
          .debugAcquireMutex('probe')
          .timeout(const Duration(seconds: 1));
      release();
    });

    test('connected auto no-ops on the best region', () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys(const []);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/vpn-regions')) {
            // The live server sits in the lowest-load region.
            return [
              regionJson('r-best', 'srv-1', 1),
              regionJson('r-heavy', 'srv-h', 10),
            ];
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await seedConnected(container, store, tunnel);
      events.clear();

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, ['GET:/vpn-regions']);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
      expect(state.message, contains('Already on'));
    });

    test('connected auto switches one-shot without pinning', () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys([const Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/vpn-regions')) {
            return [
              regionJson('r-old', 'srv-1', 9),
              regionJson('r-best', 'srv-2', 1),
            ];
          }
          if (o.path.endsWith('/switch')) {
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await seedConnected(container, store, tunnel);
      events.clear();

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      // One-shot: the move lands without pinning, so the next connect
      // re-picks instead of sticking to srv-2.
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
    });

    test('auto peerless bind racing a live peer reloads config', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('RACE-PRIV', 'RACE-PUB')]);
      var configCalls = 0;
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-best', 'srv-b', 1)];
          }
          if (o.path.endsWith('/config')) {
            configCalls++;
            // Peerless on the probe, but a peer appears before the bind
            // lands: the one-shot POST 409s and the flow reloads config.
            if (configCalls == 1) throw peerless(o);
            return dialJson(serverId: 'srv-b', serverName: 'b');
          }
          if (o.path.endsWith('/connect')) throw alreadyConnected(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      container.read(connectionProvider.notifier).debugTunnel = FakeTunnel(
        events,
      );

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, [
        'GET:/vpn-regions',
        'GET:/vpn-devices/dev-1/config',
        'POST:/vpn-devices/dev-1/connect',
        'GET:/vpn-devices/dev-1/config',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-b');
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
    });

    test(
      'disconnect during discovery is not undone by the in-flight connect',
      () async {
        final events = <String>[];
        final store = FakeStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        final regionsStarted = Completer<void>();
        final releaseRegions = Completer<void>();
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              events.add('${options.method}:${options.path}');
              if (options.path.endsWith('/vpn-regions')) {
                regionsStarted.complete();
                await releaseRegions.future;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: [regionJson('r-best', 'srv-b', 1)],
                  ),
                );
                return;
              }
              if (options.path.endsWith('/disconnect')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'disconnected_peers': 1},
                  ),
                );
                return;
              }
              // A live peer on the best target: the buggy path would reuse it
              // and start the tunnel, silently reversing the Disconnect.
              if (options.path.endsWith('/config')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: dialJson(serverId: 'srv-b', serverName: 'b'),
                  ),
                );
                return;
              }
              throw StateError('unexpected ${options.path}');
            },
          ),
        );
        final container = makeContainer(
          store: store,
          keys: FakeKeys(const []),
          api: VpnApi(dio),
        );
        final ctl = container.read(connectionProvider.notifier);
        ctl.debugTunnel = FakeTunnel(events);

        // Auto (unpinned) discovery is in flight …
        final quick = ctl.quickConnect();
        await regionsStarted.future;
        // … when the user taps Disconnect, which completes first.
        await ctl.disconnect();
        expect(container.read(connectionProvider).phase, ConnPhase.idle);
        releaseRegions.complete();
        await quick;

        // The later Disconnect wins: the in-flight connect must not probe,
        // bind, or start a tunnel behind it.
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.idle);
        expect(state.dial, isNull);
        expect(events, contains('GET:/vpn-regions'));
        expect(events, contains('POST:/vpn-devices/dev-1/disconnect'));
        expect(
          events.where(
            (e) =>
                e == 'tunnel:start' ||
                e.contains('/config') ||
                e.contains('/connect'),
          ),
          isEmpty,
        );
      },
    );

    test('working guard is a no-op', () async {
      final events = <String>[];
      final store = FakeStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      container.read(connectionProvider.notifier).snap = const ConnState(
        phase: ConnPhase.working,
        message: 'Switching…',
      );

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, isEmpty);
      expect(container.read(connectionProvider).phase, ConnPhase.working);
    });
  });
}
