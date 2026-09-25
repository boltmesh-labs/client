import 'dart:convert';

import 'package:boltmesh/core/clock.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/domain/tunnel_policy.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef ColdStore = support.FakeDeviceStore;

class ColdKeys extends support.FakeKeys {
  ColdKeys() : super(null, const Keypair('PRIV', 'PUB'));
}

class ColdTunnel extends support.FakeTunnel {
  ColdTunnel(
    List<String> events, {
    VpnStage stage = VpnStage.disconnected,
    Map<String, dynamic> traffic = const {'totalDownload': 1000},
  }) : super(events: events, stageValue: stage, traffic: traffic);
}

// Immediate-dead gateway probe (harness `DeadGatewayProbe`): outside-stop
// corroboration never waits on real 2s UDP timeouts in tests.

/// Fresh container = killed-and-reopened app: in-memory state is idle, the
/// [store] contents (device, keys, target, cached dial) survived.
(ProviderContainer, ConnectionController) coldContainer({
  required ColdStore store,
  required ColdTunnel tunnel,
  required VpnApi api,
  Clock? clock,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(ColdKeys()),
      vpnApiProvider.overrideWithValue(api),
      gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
      networkMonitorProvider.overrideWithValue(
        support.FakeNetworkMonitor(true),
      ),
      if (clock != null) clockProvider.overrideWithValue(clock),
    ],
  );
  addTearDown(() async {
    // Let in-flight stage events settle before dispose unwinds timers.
    await tunnel.close();
    container.dispose();
  });
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  return (container, ctl);
}

VpnApi configApi(
  List<String> events,
  dynamic Function(RequestOptions options) respond,
) => VpnApi(recordingDio(events, respond));

Future<void> settleEvents([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('isColdTransitionalStage', () {
    test('handshake stages are transitional', () {
      expect(isColdTransitionalStage(VpnStage.connecting), isTrue);
      expect(isColdTransitionalStage(VpnStage.waitingConnection), isTrue);
      expect(isColdTransitionalStage(VpnStage.authenticating), isTrue);
      expect(isColdTransitionalStage(VpnStage.reconnect), isTrue);
      expect(isColdTransitionalStage(VpnStage.preparing), isTrue);
    });

    test('steady and terminal stages are not transitional', () {
      expect(isColdTransitionalStage(VpnStage.connected), isFalse);
      expect(isColdTransitionalStage(VpnStage.disconnected), isFalse);
      expect(isColdTransitionalStage(VpnStage.disconnecting), isFalse);
      expect(isColdTransitionalStage(VpnStage.denied), isFalse);
      expect(isColdTransitionalStage(VpnStage.noConnection), isFalse);
      expect(isColdTransitionalStage(VpnStage.exiting), isFalse);
    });
  });

  group('reconcileColdStart', () {
    test('connected tunnel restores without restarting it', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastTarget(
        regionId: null,
        serverId: 'srv-1',
        explicitTarget: true,
      );
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(state.dial?.serverName, 'one');
      expect(state.serverId, 'srv-1');
      expect(state.message, 'Connected');
      // Server truth confirmed, tunnel untouched.
      expect(events, contains('GET:/vpn-devices/dev-1/config'));
      expect(events, isNot(contains('tunnel:start')));
      expect(events, isNot(contains('tunnel:stop')));
    });

    test('restore without a saved pin stays on Auto', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(jsonEncode(dialJson()));
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      // No saved pin: the restored session stays unpinned (Auto) instead
      // of collapsing onto the restored server.
      expect(state.regionId, isNull);
      expect(state.serverId, isNull);
      expect(state.explicitTarget, isFalse);
      expect(events, isNot(contains('tunnel:start')));
    });

    test('noConnection restores like connected', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.noConnection);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(events, isNot(contains('tunnel:start')));
    });

    test('offline with cached dial stays optimistically connected', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(
        jsonEncode(dialJson(serverName: 'cached-server')),
      );
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      // Last-target label while the backend is unreachable.
      expect(state.dial?.serverName, 'cached-server');
      expect(events, isNot(contains('tunnel:start')));
      expect(ctl.debugColdWatchArmed, isTrue);
    });

    test('offline without cached dial stays idle, never working', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('Tap Connect to reconcile'));
      expect(events, isNot(contains('tunnel:start')));
      expect(ctl.debugColdWatchArmed, isTrue);
    });

    test('stale peerless tunnel is stopped, device kept', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw peerless(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.dial, isNull);
      expect(state.message, contains('Session expired'));
      expect(events, contains('tunnel:stop'));
      expect(events, isNot(contains('tunnel:start')));
      // Device kept for a fresh bind on the next Connect.
      expect(await store.deviceId(), 'dev-1');
      expect(ctl.debugColdWatchArmed, isFalse);
    });

    test('revoked device is forgotten and the tunnel stopped', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw missingDevice(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('removed'));
      expect(events, contains('tunnel:stop'));
      expect(await store.deviceId(), isNull);
    });

    test('disconnected tunnel is a no-op without network', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(
          events,
          (o) => throw StateError('must not call ${o.path}'),
        ),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(events, isEmpty);
    });

    test('denied and disconnecting stay idle without network', () async {
      for (final stage in [VpnStage.denied, VpnStage.disconnecting]) {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        final tunnel = ColdTunnel(events, stage: stage);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(
            events,
            (o) => throw StateError('must not call ${o.path}'),
          ),
        );

        await ctl.reconcileColdStart();

        expect(container.read(connectionProvider).phase, ConnPhase.idle);
        expect(events, isEmpty);
      }
    });

    test(
      'lying disconnected stage with cache bounces via server truth',
      () async {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(
          jsonEncode(dialJson(serverName: 'cached-server')),
        );
        // Fresh backend in a re-attached engine reports no running tunnels
        // while the OS TUN is still up: the stage lies, but the survivor is
        // handle-less here, so server truth bounces (stop + start) to give
        // this backend ownership instead of adopting the ghost.
        final tunnel = ColdTunnel(events);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(state.message, 'Connected');
        expect(events, contains('GET:/vpn-devices/dev-1/config'));
        expect(events, contains('tunnel:stop'));
        expect(events, contains('tunnel:start'));
      },
    );

    test(
      'down read + unknown liveness restarts the tunnel on the fresh dial',
      () async {
        // Regression for the Android cold-restart report: the handshake
        // reader cannot see a tunnel this process never started (null),
        // traffic is unreadable (dead tunnel), the gateway probe is dead —
        // all-unknown evidence used to strand the app in a connected
        // "Verifying…" limbo until the 150s handshake aging tore it down.
        // Server truth proved the peer bound, so the confirm must restore
        // the data path by restarting the tunnel on the fresh dial.
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events, traffic: const {});
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.message, 'Connected');
        expect(state.healthNote, isNull);
        expect(state.dial?.serverId, 'srv-1');
        expect(events, contains('GET:/vpn-devices/dev-1/config'));
        expect(events, contains('tunnel:stop'));
        expect(events, contains('tunnel:start'));
      },
    );

    test(
      'down read with matching live peer still bounces for ownership',
      () async {
        // The OS tunnel survived with the server-confirmed config (same
        // server key on the same endpoint), but this backend never owned
        // it: adopting would leave a ghost no later disconnect can kill,
        // so the restore bounces onto the fresh dial instead.
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events, traffic: const {});
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );
        ctl.debugActivePeer = const ActivePeer(
          publicKey: 'SRV',
          endpoint: '203.0.113.10:51820',
        );

        await ctl.reconcileColdStart();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.message, 'Connected');
        expect(state.dial?.serverId, 'srv-1');
        expect(events, contains('GET:/vpn-devices/dev-1/config'));
        expect(events, contains('tunnel:stop'));
        expect(events, contains('tunnel:start'));
      },
    );

    test('denied stage with cache bounces via server truth', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(jsonEncode(dialJson()));
      final tunnel = ColdTunnel(events, stage: VpnStage.denied);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(events, contains('GET:/vpn-devices/dev-1/config'));
      expect(events, contains('tunnel:stop'));
      expect(events, contains('tunnel:start'));
    });

    test('down-read stage with cache but offline stays verifying', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(
        jsonEncode(dialJson(serverName: 'cached-server')),
      );
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      // A down read must never show optimistic Connected while server
      // truth is unreachable: stay verifying with the watch armed so a
      // later stage event retries the confirm.
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.working);
      expect(state.message, contains('Verifying'));
      expect(state.dial?.serverName, 'cached-server');
      expect(ctl.debugColdWatchArmed, isTrue);
      expect(events, isNot(contains('tunnel:start')));
    });

    test('down-read offline terminal event falls back to idle', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(
        jsonEncode(dialJson(serverName: 'cached-server')),
      );
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          if (o.path.endsWith('/disconnect')) return '';
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();
      expect(container.read(connectionProvider).phase, ConnPhase.working);
      expect(ctl.debugColdWatchArmed, isTrue);

      // The parked working state carries the cached dial; a terminal stage
      // event must still rescue it to idle instead of stranding the user on
      // a disabled spinner.
      tunnel.emit(VpnStage.disconnected);
      await settleEvents();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('VPN stopped'));
      expect(ctl.debugColdWatchArmed, isFalse);
    });

    test('down-read offline connected event retries the confirm', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(
        jsonEncode(dialJson(serverName: 'cached-server')),
      );
      var online = false;
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) {
            if (!online) throw networkTimeout(o);
            return dialJson();
          }
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();
      expect(container.read(connectionProvider).phase, ConnPhase.working);
      expect(ctl.debugColdWatchArmed, isTrue);

      online = true;
      tunnel.emit(VpnStage.connected);
      await settleEvents();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(ctl.debugColdWatchArmed, isFalse);
      expect(events, isNot(contains('tunnel:start')));
    });

    test('lying disconnected stage with stale peer stops the tunnel', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(jsonEncode(dialJson()));
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw peerless(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.dial, isNull);
      expect(state.message, contains('Session expired'));
      expect(events, contains('tunnel:stop'));
      // Ghost-kill replaced the reclaim-start: the native kill runs on the
      // owning backend directly, so no new tunnel is ever started here.
      expect(events, isNot(contains('tunnel:start')));
      // The dead peer's cached dial is dropped so a later offline cold start
      // cannot resurrect it.
      expect(await store.lastDialJson(), isNull);
    });

    test(
      'down-read cold restore with a null handshake and no reader bounces',
      () async {
        // Sibling of the external-stop regression, for the cold-restore
        // liveness read. `isHandshakeStale` defaults `readerSupported: true`,
        // so a call site that forgets the argument counts a permanent null
        // (no native handshake reader exists on any Apple platform) as
        // "never handshook" and, with a terminal stage and a performed-dead
        // gateway, ghost-kills a tunnel that may be perfectly alive.
        //
        // Apple is simulated by pointing the host handshake channel at a
        // platform with no native handler and leaving the test seam unset, so
        // the read resolves null. The gateway probe is the harness's
        // immediate-dead double, so the remaining corroboration the
        // corroborated-dead branch needs is already in hand.
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        // Terminal stage (the `disconnected` default) plus no traffic
        // counters: only the unreadable handshake can vouch for liveness,
        // and it cannot.
        final tunnel = ColdTunnel(events, traffic: const {});
        final clock = support.FakeClock();
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          clock: clock,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) {
              // The restore anchors `_connectedAt` before confirming, so a
              // fast confirm leaves the never-handshook window closed and the
              // reader-support argument unobservable. Age past it during the
              // confirm to model a slow restore.
              clock.advance(const Duration(minutes: 5));
              return dialJson();
            }
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();

        // Absence of evidence is unknown, not death: the restore bounces onto
        // the server-confirmed peer rather than reporting an outside kill.
        // The bounce's start itself fails (an iOS start needs the
        // VPN_PROVIDER_BUNDLE_ID define this suite does not set), which does
        // not change the decision under test.
        final state = container.read(connectionProvider);
        expect(state.dial?.serverId, 'srv-1');
        expect(state.message, isNot(contains('outside the app')));
      },
    );

    test(
      'post-restore grace ignores the replayed disconnected stage',
      () async {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        // The unknown-liveness path now restarts (clearing the anchor), so
        // set the verified-promote anchor this grace test simulates.
        ctl.debugColdRestoreConfirmedAt = DateTime.now();
        events.clear();

        // The stage stream replays the fresh-backend lie right after the
        // confirm: it must not tear down the restored session nor release
        // the server peer.
        tunnel.emit(VpnStage.disconnected);
        await settleEvents();

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(events.where((e) => e.contains('/disconnect')), isEmpty);
        expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
      },
    );

    test(
      'post-restore grace expiry with corroborated death tears down',
      () async {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        // Age the confirm past the grace window and let the handshake go
        // stale: a later outside-kill is real and must be honored (without
        // releasing the server peer).
        ctl.debugColdRestoreConfirmedAt = DateTime.now().subtract(
          const Duration(minutes: 1),
        );
        ctl.debugHandshakeReader = () async =>
            DateTime.now().subtract(const Duration(minutes: 5));
        events.clear();

        tunnel.emit(VpnStage.disconnected);
        await settleEvents(20);

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.idle);
        expect(state.message, contains('outside the app'));
        expect(events.where((e) => e.contains('/disconnect')), isEmpty);
        expect(events, contains('tunnel:stop'));
        // Ghost-kill downs the owning backend directly: no reclaim-start.
        expect(events, isNot(contains('tunnel:start')));
        expect(ctl.debugColdRestoreConfirmedAt, isNull);
      },
    );

    test(
      'external stop with a null handshake and no reader support defers',
      () async {
        // Regression: `isHandshakeStale` defaults `readerSupported: true`, so
        // a call site that forgets the argument reads a permanent null — every
        // Apple platform has no native handshake reader — as "never
        // handshook". That stale-confirms the peer and, with a terminal stage
        // and a performed-dead gateway, tears down a live tunnel. Absence of
        // evidence must defer to the health/status machinery instead.
        //
        // Simulate Apple by pointing the host handshake channel at a platform
        // with no native handler (so `handshakeReaderSupported` is false and
        // the read resolves null) and leaving the test seam unset. Applied
        // after the restore so the iOS-only bundle-id requirement does not
        // fail the bounce that establishes the session.
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events);
        // Age the session past the never-handshook grace so a null read is
        // only ever *counted* if the call site believes a reader exists.
        final clock = support.FakeClock();
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          clock: clock,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        // Past the cold-restore grace, so the outside stop is verified
        // instead of ignored, and past the never-handshook window, so a null
        // read is only counted if the call site believes a reader exists.
        ctl.debugColdRestoreConfirmedAt = clock.now().subtract(
          const Duration(minutes: 1),
        );
        clock.advance(const Duration(minutes: 5));
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        events.clear();

        tunnel.emit(VpnStage.disconnected);
        await settleEvents(20);

        // The handshake is unreadable, not stale: the session must survive
        // and keep the tunnel it cannot prove is dead.
        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(events, isNot(contains('tunnel:stop')));
        expect(events.where((e) => e.contains('/disconnect')), isEmpty);
      },
    );

    test(
      'post-restore grace expiry with a live tunnel adopts, never kills',
      () async {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        // The replayed lie arrives past the grace window, but the server
        // peer is alive and the handshake is fresh: adopt, never kill.
        // A real (non-null) handshake timestamp is positive liveness even
        // when the cold-restore anchor is still young.
        ctl.debugColdRestoreConfirmedAt = DateTime.now().subtract(
          const Duration(minutes: 1),
        );
        ctl.debugHandshakeReader = () async => DateTime.now();
        events.clear();

        tunnel.emit(VpnStage.disconnected);
        await settleEvents(20);

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(state.healthNote, isNull);
        expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
        expect(events.where((e) => e.contains('/disconnect')), isEmpty);
      },
    );

    test(
      'disconnected stage while an op holds the mutex defers to the holder',
      () async {
        final events = <String>[];
        final store = ColdStore();
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        await store.setLastDialJson(jsonEncode(dialJson()));
        final tunnel = ColdTunnel(events);
        final (container, ctl) = coldContainer(
          store: store,
          tunnel: tunnel,
          api: configApi(events, (o) {
            if (o.path.endsWith('/config')) return dialJson();
            throw StateError('unexpected ${o.path}');
          }),
        );

        await ctl.reconcileColdStart();
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        ctl.debugColdRestoreConfirmedAt = DateTime.now().subtract(
          const Duration(minutes: 1),
        );
        events.clear();

        // A confirm in flight (mutex held): the event must not flip to idle
        // nor touch the tunnel — the holder reconciles on completion.
        final release = await ctl.debugAcquireMutex('test-op');
        try {
          tunnel.emit(VpnStage.disconnected);
          await settleEvents();
        } finally {
          release();
        }

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
      },
    );

    test('ghost stop never restarts the tunnel, even mid-handover', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(jsonEncode(dialJson()));
      final tunnel = ColdTunnel(events);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw peerless(o);
          throw StateError('unexpected ${o.path}');
        }),
      );
      // A fresh session taking over must never observe a reclaim start:
      // the ghost-kill downs the owning backend directly.
      var started = false;
      tunnel.onStart = () async {
        started = true;
      };

      await ctl.reconcileColdStart();

      expect(events, contains('tunnel:stop'));
      expect(started, isFalse);
      expect(events, isNot(contains('tunnel:start')));
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
    });

    test('unreadable stage with cache restores via server truth', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(jsonEncode(dialJson()));
      final tunnel = ColdTunnel(events)..failStage = true;
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(events, contains('GET:/vpn-devices/dev-1/config'));
      expect(events, isNot(contains('tunnel:start')));
    });

    test('unreadable stage without cache stays idle', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events)..failStage = true;
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(
          events,
          (o) => throw StateError('must not call ${o.path}'),
        ),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(events, isEmpty);
    });

    test('connecting restores to working, then connected on confirm', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.connecting);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(events, isNot(contains('tunnel:start')));
    });

    test('transitional offline stays working with the watch armed', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.waitingConnection);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.working);
      expect(state.message, contains('Restoring'));
      expect(ctl.debugColdWatchArmed, isTrue);
    });

    test('no device is a no-op without touching the tunnel', () async {
      final events = <String>[];
      final store = ColdStore();
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(
          events,
          (o) => throw StateError('must not call ${o.path}'),
        ),
      );

      await ctl.reconcileColdStart();

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(events, isEmpty);
    });

    test('already-connected session is untouched', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final api = configApi(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) {
          return {
            'device_id': 'dev-1',
            'status': 'active',
            'suspended_reason': null,
          };
        }
        throw StateError('unexpected ${o.path}');
      });
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: api,
      );
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      events.clear();

      await ctl.reconcileColdStart();

      expect(events, isEmpty);
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
    });

    test('stage event retries an armed restore once online', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      var online = false;
      final tunnel = ColdTunnel(events, stage: VpnStage.waitingConnection);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) {
            if (!online) throw networkTimeout(o);
            return dialJson();
          }
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();
      expect(container.read(connectionProvider).phase, ConnPhase.working);
      expect(ctl.debugColdWatchArmed, isTrue);

      online = true;
      tunnel.emit(VpnStage.connected);
      await settleEvents();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-1');
      expect(ctl.debugColdWatchArmed, isFalse);
      expect(events, isNot(contains('tunnel:start')));
    });

    test('terminal stage event while armed falls back to idle', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events, stage: VpnStage.waitingConnection);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          if (o.path.endsWith('/disconnect')) return '';
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();
      expect(container.read(connectionProvider).phase, ConnPhase.working);

      tunnel.emit(VpnStage.disconnected);
      await settleEvents();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('VPN stopped'));
      expect(ctl.debugColdWatchArmed, isFalse);
    });
  });

  group('cached dial lifecycle', () {
    test('connect persists the dial, disconnect clears it', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final tunnel = ColdTunnel(events);
      final api = configApi(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/disconnect')) return {'disconnected_peers': 1};
        throw StateError('unexpected ${o.path}');
      });
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: api,
      );

      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);

      final raw = await store.lastDialJson();
      expect(raw, isNotNull);
      final cached = DialParams.fromJson(
        jsonDecode(raw!) as Map<String, dynamic>,
      );
      expect(cached.serverId, 'srv-1');
      expect(cached.deviceId, 'dev-1');

      await ctl.disconnect();
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(await store.lastDialJson(), isNull);
    });

    test('stale cached dial from another device is ignored', () async {
      final events = <String>[];
      final store = ColdStore();
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      await store.setLastDialJson(
        jsonEncode(dialJson(deviceId: 'dev-OTHER', serverName: 'stale')),
      );
      final tunnel = ColdTunnel(events, stage: VpnStage.connected);
      final (container, ctl) = coldContainer(
        store: store,
        tunnel: tunnel,
        api: configApi(events, (o) {
          if (o.path.endsWith('/config')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }),
      );

      await ctl.reconcileColdStart();

      // The foreign dial must never label this device's session.
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.dial, isNull);
    });
  });
}
