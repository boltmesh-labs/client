// Regression coverage for the stored WireGuard key being authoritative on
// every connect path. The backend owns the peer, so the client no longer
// reconciles a divergent server key (same-key replay + in-place rotate); it
// simply hands over the key it holds and starts on the dial the server returns.
//
// * `connect` sends the stored key and never rotates on its own;
// * a server move (`switchServer`) reuses that same key — the client mints no
//   new one — and a failed restart leaves the store untouched;
// * a `rotate` does mint a fresh key, persists it once the server has
//   committed, and keeps it when the tunnel restart fails;
// * a cold start re-ensures the stored key with the same idempotent connect.

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
  test('connect sends the stored key and does not rotate', () async {
    final events = <String>[];
    final store = support.FakeDeviceStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        // The idempotent connect makes the server peer match the key we
        // hand over and echoes it back.
        if (o.path.endsWith('/connect')) {
          expect((o.data as Map)['public_key'], 'OLD-PUB');
          return dialJson(clientPublicKey: 'OLD-PUB');
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = support.FakeTunnel(events: events);
    // Empty queue: an unexpected client-side rotation would throw loudly.
    final container = makeContainer(
      store: store,
      keys: support.FakeKeys(const []),
      api: api,
    );
    container.read(connectionProvider.notifier).debugTunnel = tunnel;

    await container.read(connectionProvider.notifier).connect();

    expect(events, ['POST:/vpn-devices/dev-1/connect', 'tunnel:start']);
    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test(
    'switch reuses the stored key and keeps it when the restart fails',
    () async {
      final events = <String>[];
      final store = support.FakeDeviceStore();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/connect')) {
            // The seed (no target) stays on srv-1; the switch names srv-2.
            expect((o.data as Map)['public_key'], 'OLD-PUB');
            if ((o.data as Map)['server_id'] == 'srv-2') {
              return dialJson(serverId: 'srv-2', serverName: 'two');
            }
            return dialJson();
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
      // Empty key queue: the move must not mint a key.
      final container = makeContainer(
        store: store,
        keys: support.FakeKeys(const []),
        api: api,
      );
      await seedConnected(container, store, tunnel);
      events.clear();

      await container
          .read(connectionProvider.notifier)
          .switchServer(regionId: null, serverId: 'srv-2');

      // The move reused the key we held: nothing to roll back, so the store is
      // untouched even though the restart failed.
      expect(await store.privateKey(), 'OLD-PRIV');
      expect(await store.publicKey(), 'OLD-PUB');
      expect(container.read(connectionProvider).phase, ConnPhase.error);
      expect(events, [
        'POST:/vpn-devices/dev-1/connect',
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
          if (o.path.endsWith('/connect')) return dialJson();
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

      // The server committed NEW-PUB before the failed restart: rolling the
      // store back to OLD-PUB would diverge permanently.
      expect(await store.privateKey(), 'NEW-PRIV');
      expect(await store.publicKey(), 'NEW-PUB');
      expect(container.read(connectionProvider).phase, ConnPhase.error);
      expect(events, [
        'POST:/vpn-devices/dev-1/connect',
        'tunnel:stop',
        'tunnel:start',
      ]);
    },
  );

  test('cold start re-ensures the stored key without rebinding', () async {
    final events = <String>[];
    final store = support.FakeDeviceStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    await store.setLastDialJson(jsonEncode(dialJson()));
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) {
          // The key we hold is the one handed over; the server confirms it.
          expect((o.data as Map)['public_key'], 'OLD-PUB');
          return dialJson();
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final tunnel = support.FakeTunnel(events: events);
    final container = ProviderContainer(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        keyManagerProvider.overrideWithValue(support.FakeKeys(const [])),
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

    // The tunnel is up and the key already matches, so the restore adopts it
    // without restarting or minting a new key.
    expect(events, ['POST:/vpn-devices/dev-1/connect']);
    expect(await store.privateKey(), 'OLD-PRIV');
    expect(await store.publicKey(), 'OLD-PUB');
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test('a fresh-key bind keeps the store clean when the POST never lands', () async {
    final events = <String>[];
    // Device known but its keypair is gone (lost identity): the connect path
    // mints one and binds it. A transport failure must surface the failure and
    // must not persist the ephemeral key.
    final store = support.FakeDeviceStore();
    await store.setDeviceId('dev-1');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/connect')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(
      store: store,
      keys: support.FakeKeys([const Keypair('NEW-PRIV', 'NEW-PUB')]),
      api: api,
    );
    container.read(connectionProvider.notifier).debugTunnel =
        support.FakeTunnel();

    await container.read(connectionProvider.notifier).connect();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(
      state.message,
      'Connect request failed. Check your connection and retry.',
    );
    expect(await store.privateKey(), isNull);
    expect(await store.publicKey(), isNull);
  });
}
