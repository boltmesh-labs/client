import 'dart:convert';

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_tunnel_adapter.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef HelperStore = support.FakeDeviceStore;

/// Container on the privileged-helper transport: the controller talks to the
/// scripted [socket] in place of a real `boltmeshd`, so the recovery paths
/// (daemon dies, daemon restarts, stale cached config, app relaunch) run
/// without a socket on disk.
(ProviderContainer, ConnectionController) helperContainer({
  required HelperStore store,
  required support.FakeHelperSocket socket,
  required VpnApi api,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(
        support.FakeKeys(const [Keypair('PRIV', 'PUB')]),
      ),
      vpnApiProvider.overrideWithValue(api),
      tunnelAdapterProvider.overrideWithValue(
        HelperTunnelAdapter(client: HelperClient(socket: socket)),
      ),
      gatewayProbeProvider.overrideWithValue(support.FakeGatewayProbe(false)),
      networkMonitorProvider.overrideWithValue(
        support.FakeNetworkMonitor(true),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container, container.read(connectionProvider.notifier));
}

/// Store seeded as a previously connected device whose helper tunnel survived.
Future<void> seedDevice(HelperStore store) async {
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
}

/// Drives a real connect over the helper transport and leaves a fresh
/// handshake so the health machinery holds the session steady.
Future<void> seedConnected(
  ProviderContainer container,
  ConnectionController ctl,
  HelperStore store,
) async {
  await seedDevice(store);
  ctl.debugHandshakeReader = () async => DateTime.now();
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
}

void main() {
  group('helper transport failure during a live session', () {
    test('daemon reads failing never tear the session down', () async {
      final events = <String>[];
      final store = HelperStore();
      final socket = support.FakeHelperSocket();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );
      await seedConnected(container, ctl, store);
      final opsAfterSeed = socket.ops.length;
      events.clear();

      // The daemon is killed mid-session: every read resolves unknown.
      socket.fail = true;
      for (var i = 0; i < 3; i++) {
        await ctl.checkHealthOnce();
      }
      await ctl.pollStatusOnce();
      await ctl.pollStatusOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.pollFailures, 0);
      expect(state.healthNote, isNull);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 0);
      // A wedged helper transport is not a tunnel command: no restart, no
      // teardown, and no control-plane call was skipped.
      final after = socket.ops.sublist(opsAfterSeed);
      expect(after, isNot(contains('up')));
      expect(after, isNot(contains('down')));
    });

    test('the session keeps running once the daemon answers again', () async {
      final events = <String>[];
      final store = HelperStore();
      final socket = support.FakeHelperSocket();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );
      await seedConnected(container, ctl, store);
      final opsAfterSeed = socket.ops.length;

      socket.fail = true;
      await ctl.checkHealthOnce();
      socket.fail = false;
      await ctl.checkHealthOnce();
      await ctl.pollStatusOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.healthNote, isNull);
      final after = socket.ops.sublist(opsAfterSeed);
      expect(after, isNot(contains('up')));
      expect(after, isNot(contains('down')));
    });
  });

  group('service termination', () {
    test('disconnect reaches idle when the daemon is gone, and a later connect recovers', () async {
      final events = <String>[];
      final store = HelperStore();
      final socket = support.FakeHelperSocket();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/disconnect')) {
            return {'disconnected_peers': 1};
          }
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );
      await seedConnected(container, ctl, store);
      events.clear();

      // The helper dies: teardown still must not strand the user.
      socket.fail = true;
      await ctl.disconnect();

      var state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('Disconnected'));
      expect(events, contains('POST:/vpn-devices/dev-1/disconnect'));
      // The stop was attempted (and retried) even though it never landed.
      expect(socket.ops, contains('down'));
      expect(await store.lastDialJson(), isNull);

      // Daemon restarts: a fresh connect rebinds on the same device.
      socket.fail = false;
      events.clear();
      await ctl.connect();

      state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
    });
  });

  group('app relaunch with a surviving helper tunnel', () {
    Future<HelperStore> storeWithCachedDial() async {
      final store = HelperStore();
      await seedDevice(store);
      await store.setLastDialJson(
        jsonEncode(dialJson(serverName: 'cached-server')),
      );
      return store;
    }

    test('daemon up restores without restarting the tunnel', () async {
      final events = <String>[];
      final store = await storeWithCachedDial();
      final socket = support.FakeHelperSocket();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.message, 'Connected');
      expect(events, contains('GET:/vpn-devices/dev-1/config'));
      expect(socket.ops, isNot(contains('up')));
      expect(socket.ops, isNot(contains('down')));
    });

    test(
      'daemon unreachable leaves the cached session optimistically connected',
      () async {
        final events = <String>[];
        final store = await storeWithCachedDial();
        // Negotiation answers (so init succeeds) but the reads do not.
        final socket = support.FakeHelperSocket()..failingOps.add('status');
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/config')) throw networkTimeout(o);
            throw StateError('unexpected ${o.path}');
          }),
        );
        final (container, ctl) = helperContainer(
          store: store,
          socket: socket,
          api: api,
        );

        await ctl.reconcileColdStart();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverName, 'cached-server');
        expect(ctl.debugColdWatchArmed, isTrue);
        expect(socket.ops, isNot(contains('up')));
      },
    );

    test('a lying down stage bounces on server truth', () async {
      final events = <String>[];
      final store = await storeWithCachedDial();
      final socket = support.FakeHelperSocket(
        status: support.helperStatusJson(up: false, stage: 'disconnected'),
      );
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(events, contains('GET:/vpn-devices/dev-1/config'));
      // The fresh backend reports no running tunnel, but the peer exists
      // server-side: bounce so this process owns the TUN.
      expect(socket.ops, contains('down'));
      expect(socket.ops, contains('up'));
    });

    test('a peerless device stops the helper tunnel and stays idle', () async {
      final events = <String>[];
      final store = await storeWithCachedDial();
      final socket = support.FakeHelperSocket();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) throw peerless(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('Session expired'));
      expect(socket.ops, contains('down'));
      expect(socket.ops, isNot(contains('up')));
      // The device is kept for a fresh bind on the next Connect.
      expect(await store.deviceId(), 'dev-1');
      // But the cached dial is dropped: the peer is known gone, so the next
      // offline cold start must not restore/verify the dead session.
      expect(await store.lastDialJson(), isNull);
    });

    test(
      'a malformed cached dial is ignored and server truth restores',
      () async {
        final events = <String>[];
        final store = await storeWithCachedDial();
        await store.setLastDialJson('{ this is not json');
        final socket = support.FakeHelperSocket();
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );
        final (container, ctl) = helperContainer(
          store: store,
          socket: socket,
          api: api,
        );

        await ctl.reconcileColdStart();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(socket.ops, isNot(contains('up')));
      },
    );

    test('no cached dial stays idle while the helper reads are down', () async {
      final events = <String>[];
      final store = HelperStore();
      await seedDevice(store);
      final socket = support.FakeHelperSocket()..failingOps.add('status');
      final api = VpnApi(
        recordingDio(
          events,
          (o) => throw StateError('must not call ${o.path}'),
        ),
      );
      final (container, ctl) = helperContainer(
        store: store,
        socket: socket,
        api: api,
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(events, isEmpty);
      expect(socket.ops, isNot(contains('up')));
    });

    test(
      'a daemon that never answers init stays idle without dialing',
      () async {
        final events = <String>[];
        final store = HelperStore();
        await seedDevice(store);
        final socket = support.FakeHelperSocket()..fail = true;
        final api = VpnApi(
          recordingDio(
            events,
            (o) => throw StateError('must not call ${o.path}'),
          ),
        );
        final (container, ctl) = helperContainer(
          store: store,
          socket: socket,
          api: api,
        );

        await ctl.reconcileColdStart();

        expect(container.read(connectionProvider).phase, ConnPhase.idle);
        expect(events, isEmpty);
        expect(socket.ops, ['ping']);
      },
    );
  });
}
