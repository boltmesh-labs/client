import 'dart:async';

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
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

/// API whose peer release fails with a non-[DioException], to prove the local
/// release knowledge is withdrawn even for an exception type the disconnect
/// handler does not name.
class ThrowingDisconnectApi extends VpnApi {
  ThrowingDisconnectApi(super.dio);

  @override
  Future<void> disconnect(String deviceId, {CancelToken? cancelToken}) async {
    throw StateError('disconnect blew up');
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

    test('reports a failed connected tunnel restart', () async {
      final events = <String>[];
      final store = FakeStore();
      final container = await seedWithStore(events, store);
      final tunnel = FakeTunnel(events);
      await seedConnected(container, store, tunnel);
      tunnel.onStart = () async => throw StateError('restart failed');
      events.clear();

      expect(
        await container.read(connectionProvider.notifier).setAllowLocal(false),
        isFalse,
      );
      expect(await store.allowLocal(), isFalse);
      expect(container.read(connectionProvider).phase, ConnPhase.error);
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
    // Empty key queue: the move reuses the stored key, never mints one.
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') {
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          return dialJson();
        }
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
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // Probe-first: the POST travels before any stop; the single stop is
    // the restart onto the new server.
    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
    // The move reused the stored key.
    expect(await store.privateKey(), 'OLD-PRIV');
  });

  test('failed switch after tunnel stop surfaces error', () async {
    final events = <String>[];
    final store = FakeStore();
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') throw networkTimeout(o);
          return dialJson();
        }
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
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');
    final state = container.read(connectionProvider);
    // The fallback path already stopped the tunnel, so claiming
    // `connected` on the old server would lie: surface `error` and let
    // Connect reconcile against server truth.
    expect(state.phase, ConnPhase.error);
    expect(state.message, contains('Tunnel stopped'));
    expect(state.dial?.serverId, 'srv-1');
    // Probe first, then one direct retry after the stop; no restart after
    // a failed POST.
    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/connect',
    ]);
  });

  test('idle switch transport failure keeps error without stopping', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) throw networkTimeout(o);
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

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // No tunnel is running while idle: a single direct attempt, no stop.
    expect(events, ['POST:/vpn-devices/dev-1/connect']);
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
    container.read(connectionProvider.notifier).selectTarget(serverId: 'srv-1');
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-1');

    expect(events, isEmpty);
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test('same-server skip from Auto pins the explicit server', () async {
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
    // seedConnected leaves Auto unpinned while the dial names srv-1.
    expect(container.read(connectionProvider).serverId, isNull);
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-1');

    expect(events, isEmpty);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.serverId, 'srv-1');
    expect(state.explicitTarget, isTrue);
    expect(state.opFailed, isFalse);
    final saved = await store.lastTarget();
    expect(saved.serverId, 'srv-1');
    expect(saved.explicitTarget, isTrue);
  });

  test(
    'a pinned target with no tunnel is switched, not called connected',
    () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/connect')) {
            return dialJson();
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: api,
      );
      container.read(connectionProvider.notifier).debugTunnel = tunnel;
      // Pin restored, nothing running: the old skip answered this with
      // "Already connected to ..." and did nothing at all.
      container
          .read(connectionProvider.notifier)
          .selectTarget(serverId: 'srv-1');

      await container
          .read(connectionProvider.notifier)
          .switchServer(regionId: null, serverId: 'srv-1');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.message, isNot(contains('Already connected to')));
      expect(events, contains('POST:/vpn-devices/dev-1/connect'));
    },
  );

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
    expect(state.serverId, isNull);
    expect(state.explicitTarget, isFalse);
    final saved = await store.lastTarget();
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
    ctl.selectTarget(serverId: 's-1');

    await ctl.switchServer(regionId: 'r-2', serverId: null);

    // The provision POST must carry only the new region, never the stale
    // server (previously leaked via selectTarget keep-semantics plus the
    // `?? state` fallback in _provision).
    expect(provisionBody, isNotNull);
    expect(provisionBody!['region_id'], 'r-2');
    expect(provisionBody!.containsKey('server_id'), isFalse);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.serverId, 'srv-r2');
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

  test(
    'disconnect 404 wipes the dead identity for a clean reprovision',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys(const []);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/disconnect')) throw missingDevice(o);
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
      expect(state.message, contains('removed'));
      // The device row is gone server-side: keeping the local identity would
      // make the very next Connect fail with a 404 before it can reprovision.
      expect(await store.deviceId(), isNull);
      expect(await store.privateKey(), isNull);
      expect(await store.lastDialJson(), isNull);
    },
  );

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

  test('forgetDevice reports revoke failure after local cleanup', () async {
    final events = <String>[];
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) {
          return {'disconnected_peers': 1};
        }
        if (o.path == '/vpn-devices/dev-1') {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = FakeTunnel(events);
    final container = makeContainer(store: store, keys: keys, api: api);
    await seedConnected(container, store, tunnel);
    events.clear();

    await expectLater(
      container.read(connectionProvider.notifier).forgetDevice(),
      throwsA(isA<DioException>()),
    );

    expect(await store.deviceId(), isNull);
    expect(container.read(connectionProvider).phase, ConnPhase.idle);
    expect(container.read(connectionProvider).message, 'Ready');
    expect(events, contains('DELETE:/vpn-devices/dev-1'));
  });

  test('releaseDevice revokes when the identity read blips', () async {
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

    // A transient identity-read failure must not skip the hard revoke while
    // the peer release still goes through: the server row (and its plan
    // slot) would leak even though the local identity is wiped.
    var reads = 0;
    store.deviceIdHook = () async {
      reads++;
      if (reads == 1) throw StateError('keychain busy');
    };

    await container.read(connectionProvider.notifier).releaseDevice();

    expect(events, [
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/disconnect',
      'DELETE:/vpn-devices/dev-1',
    ]);
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
    'missing device on connect surfaces reprovision without a bind attempt',
    () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final keys = FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]);
      final api = VpnApi(
        recordingDio(events, (o) {
          // The idempotent connect reports the revoked/foreign device.
          if (o.path.endsWith('/connect')) throw missingDevice(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = makeContainer(store: store, keys: keys, api: api);
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = FakeTunnel(events);

      await ctl.connect();

      // A true 404 must not reprovision blindly: the identity is wiped and
      // no bind key is spent.
      expect(events, ['POST:/vpn-devices/dev-1/connect']);
      expect(await store.deviceId(), isNull);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.error);
      expect(state.message, contains('Reprovision'));
    },
  );

  test('in-tunnel switch succeeds without stopping first', () async {
    final events = <String>[];
    final store = FakeStore();
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') {
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          return dialJson();
        }
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
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    // Zero-drop order: POST first, single stop only for the restart.
    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(await store.privateKey(), 'OLD-PRIV');
  });

  test('in-tunnel failure falls back to one direct retry', () async {
    final events = <String>[];
    final store = FakeStore();
    var connectCalls = 0;
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') {
            if (connectCalls++ == 0) throw networkTimeout(o);
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          return dialJson();
        }
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
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(await store.privateKey(), 'OLD-PRIV');
  });

  test('double transport failure reports unknown status', () async {
    final events = <String>[];
    final store = FakeStore();
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') throw networkTimeout(o);
          return dialJson();
        }
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
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'POST:/vpn-devices/dev-1/connect',
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
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          // Generic app error: no retry, no stop, the old tunnel keeps
          // running.
          if ((o.data as Map)['server_id'] == 'srv-2') {
            throw idempotencyConflict(o);
          }
          return dialJson();
        }
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
    container.read(connectionProvider.notifier).debugForceThroughTunnel = true;
    events.clear();

    await container
        .read(connectionProvider.notifier)
        .switchServer(regionId: null, serverId: 'srv-2');

    expect(events, ['POST:/vpn-devices/dev-1/connect']);
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.message, contains('still on'));
  });

  test('idle switch moves the stored key onto the target', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') {
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          return dialJson();
        }
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

    await ctl.switchServer(regionId: null, serverId: 'srv-2');

    // One connect on the key we hold, moved onto the requested target.
    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
  });

  test('switch after a disconnect moves the stored key in one POST', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/disconnect')) return {'disconnected_peers': 1};
        if (o.path.endsWith('/connect')) {
          if ((o.data as Map)['server_id'] == 'srv-2') {
            return dialJson(serverId: 'srv-2', serverName: 'two');
          }
          return dialJson();
        }
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

    await ctl.disconnect();
    events.clear();

    await ctl.switchServer(regionId: null, serverId: 'srv-2');

    // The disconnect released the peer; the switch re-ensures it on the new
    // target with the key we hold — one connect, no separate bind.
    expect(events, [
      'POST:/vpn-devices/dev-1/connect',
      'tunnel:stop',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'OLD-PRIV');
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
  });

  test(
    'switch after an unconfirmed disconnect still moves the stored key',
    () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          // The release never reached the server, so the peer may still
          // exist: the connect below moves it either way.
          if (o.path.endsWith('/disconnect')) throw networkTimeout(o);
          if (o.path.endsWith('/connect')) {
            if ((o.data as Map)['server_id'] == 'srv-2') {
              return dialJson(serverId: 'srv-2', serverName: 'two');
            }
            return dialJson();
          }
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

      await ctl.disconnect();
      expect(container.read(connectionProvider).message, contains('pending'));
      events.clear();

      await ctl.switchServer(regionId: null, serverId: 'srv-2');

      expect(events, [
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:stop',
        'tunnel:start',
      ]);
      expect(await store.privateKey(), 'OLD-PRIV');
      expect(container.read(connectionProvider).dial?.serverId, 'srv-2');
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
      'idle without region auto-picks lowest load and moves its peer',
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
            // The idempotent connect ensures the stored key on the picked
            // region, moving the peer there in one call.
            if (o.path.endsWith('/connect')) {
              if ((o.data as Map)['region_id'] == 'r-best') {
                return dialJson(serverId: 'srv-b', serverName: 'b');
              }
              return dialJson();
            }
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

        // Auto re-picks fresh: discovery, then one connect onto the picked
        // region; the state stays unpinned.
        expect(events, [
          'GET:/vpn-regions',
          'POST:/vpn-devices/dev-1/connect',
          'tunnel:start',
        ]);
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-b');
        expect(state.serverId, isNull);
        expect(state.explicitTarget, isFalse);
      },
    );

    test('idle auto moves a live peer from another region', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [
              regionJson('r-old', 'srv-old', 9),
              regionJson('r-best', 'srv-best', 1),
            ];
          }
          // The peer sits in another region: the connect moves it onto the
          // picked region one-shot.
          if (o.path.endsWith('/connect')) {
            if ((o.data as Map)['region_id'] == 'r-best') {
              return dialJson(serverId: 'srv-best', serverName: 'best');
            }
            return dialJson(serverId: 'srv-old', serverName: 'old');
          }
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

      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-best');
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
    });

    test('idle auto binds a peer on the best region', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-best', 'srv-b', 1)];
          }
          // Peerless device: the connect binds the stored key on the picked
          // region and returns its dial.
          if (o.path.endsWith('/connect')) {
            return dialJson(serverId: 'srv-b', serverName: 'b');
          }
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

      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-b');
      expect(state.serverId, isNull);
    });

    test(
      'stale device on 404 wipes the identity for a fresh provision',
      () async {
        final events = <String>[];
        final store = FakeStore();
        await store.setDeviceId('stale-dev');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/vpn-regions')) {
              return [regionJson('r-best', 'srv-b', 1)];
            }
            // The stored id is gone server-side (revoked/foreign): the connect
            // 404s and the identity is wiped, so the next tap reprovisions.
            if (o.path.endsWith('/connect')) throw missingDevice(o);
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

        expect(events, [
          'GET:/vpn-regions',
          'POST:/vpn-devices/stale-dev/connect',
        ]);
        expect(await store.deviceId(), isNull);
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.error);
        expect(state.message, contains('Reprovision'));
      },
    );

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

    test('idle with pinned server re-fetches discovery and dials it', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-1', 'srv-1', 1)];
          }
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
      ctl.selectTarget(serverId: 'srv-1');

      events.clear();
      await ctl.quickConnect();

      // Every pinned connect re-fetches discovery to confirm the server is
      // still listed before dialing it.
      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.serverId, 'srv-1');
    });

    test('idle with a gone pinned server falls back to auto', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-best', 'srv-b', 1)];
          }
          // Auto dials the picked region one-shot; the peer is ensured by
          // the idempotent connect.
          if (o.path.endsWith('/connect')) {
            return dialJson(serverId: 'srv-b', serverName: 'b');
          }
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
      ctl.selectTarget(serverId: 'srv-gone', explicitTarget: true);

      events.clear();
      await ctl.quickConnect();

      // The vanished pin is dropped and the lowest-load region is dialed
      // one-shot (the state stays unpinned).
      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-b');
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
      final saved = await store.lastTarget();
      expect(saved.serverId, isNull);
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
            return [
              regionJson('r-1', 'srv-1', 0),
              regionJson('r-other', 'srv-other', 0),
            ];
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
          .selectTarget(serverId: 'srv-1');
      await container.read(connectionProvider.notifier).disconnect();
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(container.read(connectionProvider).serverId, 'srv-1');
      events.clear();

      await container.read(connectionProvider.notifier).quickConnect();

      // The pin survives the disconnect and discovery confirms it.
      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
    });

    test('persisted target is reused by a fresh container', () async {
      final events = <String>[];
      final store = FakeStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastTarget(serverId: 'srv-1', explicitTarget: true);
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [regionJson('r-1', 'srv-1', 0)];
          }
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

      expect(events, [
        'GET:/vpn-regions',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
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
      ctl.selectTarget(serverId: 'srv-1');

      await ctl.selectAuto();

      final state = container.read(connectionProvider);
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
      // Awaited persist: a following quickConnect can't resurrect the pin.
      final saved = await store.lastTarget();
      expect(saved.serverId, isNull);
      expect(saved.explicitTarget, isFalse);
    });

    test(
      'auto quickConnect drops a stored pin its own read could not act on',
      () async {
        final events = <String>[];
        final store = FakeStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        // A pin an earlier session left in storage. Normally the saved-target
        // read below redials it stickily, so the Auto branch is only reached
        // when that read fails (locked keychain) — the one state where a stale
        // pin could otherwise outlive the Auto connect and be rehydrated by
        // the next cold restore.
        await store.setLastTarget(serverId: 'srv-old', explicitTarget: true);
        store.lastTargetHook = () async => throw StateError('keychain locked');
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/vpn-regions')) {
              return [regionJson('r-best', 'srv-b', 2)];
            }
            if (o.path.endsWith('/connect')) {
              return dialJson(serverId: 'srv-b', serverName: 'b');
            }
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

        expect(events, [
          'GET:/vpn-regions',
          'POST:/vpn-devices/dev-1/connect',
          'tunnel:start',
        ]);
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-b');
        expect(state.serverId, isNull);
        final saved = await store.lastTarget();
        expect(saved.serverId, isNull);
        expect(saved.explicitTarget, isFalse);
      },
    );

    test(
      'auto switch while connected also drops the stale stored pin',
      () async {
        final events = <String>[];
        final store = FakeStore();
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/vpn-regions')) {
              return [regionJson('r-best', 'srv-b', 1)];
            }
            if (o.path.endsWith('/connect')) {
              // The seed connect stays on srv-1; the Auto move names r-best.
              if ((o.data as Map)['region_id'] == 'r-best') {
                return dialJson(serverId: 'srv-b', serverName: 'b');
              }
              return dialJson();
            }
            throw StateError('unexpected ${o.path}');
          }),
        );
        final container = makeContainer(
          store: store,
          keys: FakeKeys(const []),
          api: api,
        );
        final tunnel = FakeTunnel(events);
        await seedConnected(container, store, tunnel);
        await store.setLastTarget(serverId: 'srv-old', explicitTarget: true);
        // Same one-shot read failure as above, so the connected Auto branch
        // (a one-shot switch, no bind) is the path under test.
        store.lastTargetHook = () async => throw StateError('keychain locked');
        events.clear();

        await container.read(connectionProvider.notifier).quickConnect();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-b');
        expect(state.serverId, isNull);
        final saved = await store.lastTarget();
        expect(saved.serverId, isNull);
        expect(saved.explicitTarget, isFalse);
      },
    );

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
      expect(state.serverId, isNull);
      expect(state.message, contains('Already connected to'));
    });

    test('connected auto switches one-shot without pinning', () async {
      final events = <String>[];
      final store = FakeStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/vpn-regions')) {
            return [
              regionJson('r-old', 'srv-1', 9),
              regionJson('r-best', 'srv-2', 1),
            ];
          }
          if (o.path.endsWith('/connect')) {
            // The seed connect stays on srv-1; the Auto move names r-best.
            if ((o.data as Map)['region_id'] == 'r-best') {
              return dialJson(serverId: 'srv-2', serverName: 'two');
            }
            return dialJson();
          }
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
      events.clear();

      await container.read(connectionProvider.notifier).quickConnect();

      expect(events, contains('POST:/vpn-devices/dev-1/connect'));
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      // One-shot: the move lands without pinning, so the next connect
      // re-picks instead of sticking to srv-2.
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
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

  // The OS VPN consent dialog is asked for before `start`, so a slow "OK" tap
  // can never be mistaken for a wedged driver inside `start`'s 10s budget.
  group('VPN consent', () {
    /// Answers the app's `com.boltmesh/tunnel` host channel with [granted] for
    /// the consent request, leaving the other methods on the global stub.
    void stubConsent(bool granted) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.ghostChannel,
        (call) async => switch (call.method) {
          'requestVpnConsent' => granted,
          'killGhost' => false,
          _ => null,
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          WireGuardTunnelAdapter.ghostChannel,
          (call) async => call.method == 'killGhost' ? false : null,
        ),
      );
    }

    Future<ProviderContainer> consentContainer(List<String> events) async {
      final store = FakeStore();
      final container = makeContainer(
        store: store,
        keys: FakeKeys(const []),
        api: VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        ),
      );
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      return container;
    }

    test('a denial returns to idle and never starts the tunnel', () async {
      final events = <String>[];
      final container = await consentContainer(events);
      final tunnel = FakeTunnel(events);
      addTearDown(tunnel.close);
      stubConsent(false);

      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      await ctl.connect();

      final snap = container.read(connectionProvider);
      // A denial is a user decision, not a fault: idle and re-armed, so the
      // button works again — never the error state, which the user cannot act
      // on, and never `connected`.
      expect(snap.phase, ConnPhase.idle);
      expect(snap.message, contains('permission denied'));
      // Nothing was brought up: no wgQuick config ever reached the driver.
      expect(tunnel.configs, isEmpty);
    });

    test('granted consent proceeds to the tunnel start', () async {
      final events = <String>[];
      final container = await consentContainer(events);
      final tunnel = FakeTunnel(events);
      addTearDown(tunnel.close);
      stubConsent(true);

      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      await ctl.connect();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(tunnel.configs, hasLength(1));
    });

    test('a denial leaves the op mutex free for a retry', () async {
      final events = <String>[];
      final container = await consentContainer(events);
      final tunnel = FakeTunnel(events);
      addTearDown(tunnel.close);
      stubConsent(false);

      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.idle);

      // The second tap must reach the tunnel, so the consent step released the
      // mutex instead of leaving the op wedged mid-flight.
      stubConsent(true);
      await ctl.connect();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(tunnel.configs, hasLength(1));
    });
  });
}
