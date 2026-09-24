// Regression coverage for client/server WireGuard key divergence:
//
// * a `GET …/config` that reports a peer key the client does not hold is
//   repaired with an in-place rotation before any tunnel starts;
// * a key the server already committed is never rolled back when the tunnel
//   restart fails;
// * a cold-start restore bounces a surviving OS tunnel after such a repair.
//
// The backend echoes the active peer's public key as `client_public_key`
// (`VpnDeviceCreateOut`); these suites drive it through the shared
// `dialJson(clientPublicKey: …)` payload.

import 'dart:convert';

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

/// Fixed keypair for the cold-start rebind: any `generate()` returns it.
class RebindKeys extends support.FakeKeys {
  RebindKeys() : super(null, const Keypair('PRIV', 'PUB'));
}

ProviderContainer makeContainer({
  required support.FakeDeviceStore store,
  required support.FakeKeys keys,
  required VpnApi api,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(keys),
      vpnApiProvider.overrideWithValue(api),
      gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
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
  support.FakeDeviceStore store,
  support.FakeTunnel tunnel,
) async {
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
}

void main() {
  test(
    'connect rotates when config reports a peer key the client cannot hold',
    () async {
      final events = <String>[];
      final store = support.FakeDeviceStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      String? rotatedKey;
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            // The server's active peer holds a key whose bind response was
            // lost: the stored OLD-PUB can never handshake.
            return dialJson(clientPublicKey: 'SERVER-K1');
          }
          if (o.path.endsWith('/rotate-keys')) {
            rotatedKey = (o.data as Map)['public_key'] as String?;
            return dialJson(clientPublicKey: 'NEW-PUB');
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = support.FakeTunnel(events: events);
      final container = makeContainer(
        store: store,
        keys: support.FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]),
        api: api,
      );
      container.read(connectionProvider.notifier).debugTunnel = tunnel;

      await container.read(connectionProvider.notifier).connect();

      expect(events, [
        'GET:/vpn-devices/dev-1/config',
        'POST:/vpn-devices/dev-1/rotate-keys',
        'tunnel:start',
      ]);
      expect(rotatedKey, 'NEW-PUB');
      expect(await store.privateKey(), 'NEW-PRIV');
      expect(await store.publicKey(), 'NEW-PUB');
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
    },
  );

  test('connect starts as-is when the server peer key matches', () async {
    final events = <String>[];
    final store = support.FakeDeviceStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) {
          return dialJson(clientPublicKey: 'OLD-PUB');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = support.FakeTunnel(events: events);
    // Empty queue: an unexpected rotation would throw loudly.
    final container = makeContainer(
      store: store,
      keys: support.FakeKeys(const []),
      api: api,
    );
    container.read(connectionProvider.notifier).debugTunnel = tunnel;

    await container.read(connectionProvider.notifier).connect();

    expect(events, ['GET:/vpn-devices/dev-1/config', 'tunnel:start']);
    expect(await store.privateKey(), 'OLD-PRIV');
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test(
    'switch keeps the committed key when the tunnel restart fails',
    () async {
      final events = <String>[];
      final store = support.FakeDeviceStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            return dialJson(clientPublicKey: 'OLD-PUB');
          }
          if (o.path.endsWith('/switch')) {
            return dialJson(
              serverId: 'srv-2',
              serverName: 'two',
              clientPublicKey: 'NEW-PUB',
            );
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      var starts = 0;
      final tunnel = support.FakeTunnel(events: events)
        ..onStart = () async {
          starts++;
          if (starts >= 2) throw StateError('tunnel start failed');
        };
      final container = makeContainer(
        store: store,
        keys: support.FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]),
        api: api,
      );
      await seedConnected(container, store, tunnel);
      events.clear();

      await container
          .read(connectionProvider.notifier)
          .switchServer(regionId: null, serverId: 'srv-2');

      // The server committed NEW-PUB before the failed restart: rolling the
      // store back to OLD-PUB would diverge permanently.
      expect(await store.privateKey(), 'NEW-PRIV');
      expect(await store.publicKey(), 'NEW-PUB');
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.error);
      expect(state.dial?.serverId, 'srv-1');
      expect(events, [
        'POST:/vpn-devices/dev-1/switch',
        'tunnel:stop',
        'tunnel:start',
      ]);
    },
  );

  test(
    'rotate keeps the committed key when the tunnel restart fails',
    () async {
      final events = <String>[];
      final store = support.FakeDeviceStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            return dialJson(clientPublicKey: 'OLD-PUB');
          }
          if (o.path.endsWith('/rotate-keys')) {
            return dialJson(clientPublicKey: 'NEW-PUB');
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      var starts = 0;
      final tunnel = support.FakeTunnel(events: events)
        ..onStart = () async {
          starts++;
          if (starts >= 2) throw StateError('tunnel start failed');
        };
      final container = makeContainer(
        store: store,
        keys: support.FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]),
        api: api,
      );
      await seedConnected(container, store, tunnel);
      events.clear();

      await container.read(connectionProvider.notifier).rotateKeys();

      expect(await store.privateKey(), 'NEW-PRIV');
      expect(await store.publicKey(), 'NEW-PUB');
      expect(container.read(connectionProvider).phase, ConnPhase.error);
      expect(events, [
        'POST:/vpn-devices/dev-1/rotate-keys',
        'tunnel:stop',
        'tunnel:start',
      ]);
    },
  );

  test('cold start rebinds and bounces a divergent server key', () async {
    final events = <String>[];
    final store = support.FakeDeviceStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    await store.setLastDialJson(jsonEncode(dialJson()));
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) {
          return dialJson(clientPublicKey: 'SERVER-K1');
        }
        if (o.path.endsWith('/rotate-keys')) {
          return dialJson(clientPublicKey: 'PUB');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = support.FakeTunnel(events: events);
    final container = ProviderContainer(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        keyManagerProvider.overrideWithValue(RebindKeys()),
        vpnApiProvider.overrideWithValue(api),
        gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
        networkMonitorProvider.overrideWithValue(
          support.FakeNetworkMonitor(true),
        ),
      ],
    );
    addTearDown(() async {
      await tunnel.close();
      container.dispose();
    });
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = tunnel;

    await ctl.reconcileColdStart();

    // The surviving OS tunnel runs the stale key, so the repair must stop and
    // restart on the rebounded dial, never adopt it.
    expect(events, [
      'GET:/vpn-devices/dev-1/config',
      'POST:/vpn-devices/dev-1/rotate-keys',
      'tunnel:stop',
      'tunnel:start',
    ]);
    expect(await store.privateKey(), 'PRIV');
    expect(await store.publicKey(), 'PUB');
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test(
    'peerless switch keeps the fresh bind when the tunnel restart fails',
    () async {
      final events = <String>[];
      final store = support.FakeDeviceStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            return dialJson(clientPublicKey: 'OLD-PUB');
          }
          if (o.path.endsWith('/switch')) throw peerless(o);
          if (o.path.endsWith('/connect')) {
            return dialJson(
              serverId: 'srv-2',
              serverName: 'two',
              clientPublicKey: 'FRESH-PUB',
            );
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      var starts = 0;
      final tunnel = support.FakeTunnel(events: events)
        ..onStart = () async {
          starts++;
          if (starts >= 2) throw StateError('tunnel start failed');
        };
      // One key for the doomed switch POST, one for the fresh bind.
      final container = makeContainer(
        store: store,
        keys: support.FakeKeys([
          const Keypair('SWITCH-PRIV', 'SWITCH-PUB'),
          const Keypair('FRESH-PRIV', 'FRESH-PUB'),
        ]),
        api: api,
      );
      await seedConnected(container, store, tunnel);
      events.clear();

      await container
          .read(connectionProvider.notifier)
          .switchServer(regionId: null, serverId: 'srv-2');

      // The fresh peer is committed server-side; the failed restart must not
      // restore the switch key or the pre-switch key.
      expect(await store.privateKey(), 'FRESH-PRIV');
      expect(await store.publicKey(), 'FRESH-PUB');
      expect(container.read(connectionProvider).phase, ConnPhase.error);
      expect(events, [
        'POST:/vpn-devices/dev-1/switch',
        'tunnel:stop',
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:start',
      ]);
    },
  );
}
