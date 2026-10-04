import 'dart:async';

import 'package:boltmesh/core/clock.dart';
import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_tunnel_adapter.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
import 'package:boltmesh/features/vpn/state/connection_tuning.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/fakes.dart';
import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef FakeStore = support.FakeDeviceStore;
typedef FakeKeys = support.FakeKeys;

class FakeTunnel extends support.FakeTunnel {
  FakeTunnel(List<String> events)
    : super(events: events, traffic: const {'rx': 1000});
}

/// [FakeTunnel] whose [stopVpn] can be held open by [stopGate], so a test can
/// start a reconnect while a teardown stop is still in flight. [startDuringStop]
/// records the race the op mutex must prevent: a replacement tunnel starting
/// before the previous stop completed.
class BlockingStopTunnel extends FakeTunnel {
  BlockingStopTunnel(super.events);

  /// Completes [stopVpn]; null stops immediately.
  Completer<void>? stopGate;

  /// True while a [stopVpn] call is awaiting [stopGate].
  bool stopPending = false;

  /// Set when [startVpn] runs while a stop is still pending.
  bool startDuringStop = false;

  @override
  Future<void> stopVpn() async {
    events.add('tunnel:stop');
    stopPending = true;
    final gate = stopGate;
    if (gate != null) await gate.future;
    stopPending = false;
  }

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    if (stopPending) startDuringStop = true;
    await super.startVpn(
      serverAddress: serverAddress,
      wgQuickConfig: wgQuickConfig,
      providerBundleIdentifier: providerBundleIdentifier,
      excludedApps: excludedApps,
      includedApps: includedApps,
    );
  }
}

ProviderContainer makeContainer({
  required FakeStore store,
  required FakeKeys keys,
  required VpnApi api,
  Clock? clock,
  GatewayProbe? gatewayProbe,
  ControlPlaneProbe? controlProbe,
  TunnelAdapter? tunnel,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(keys),
      vpnApiProvider.overrideWithValue(api),
      // A suite that needs the privileged helper (the stream rung only runs
      // there) injects it; the rest drive the plugin adapter through
      // [seedConnected]'s `debugTunnel`.
      if (tunnel != null) tunnelAdapterProvider.overrideWithValue(tunnel),
      if (clock != null) clockProvider.overrideWithValue(clock),
      // Default pins the diagnostic pipeline to the legacy total-blackout
      // path: link up, gateway dead, control plane unreachable. Keeps
      // existing heal-ladder expectations deterministic with zero real I/O.
      // Tests exercising the unprobeable-echo / reachable-control-plane path
      // inject their own probes.
      networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
      gatewayProbeProvider.overrideWithValue(
        gatewayProbe ?? DeadGatewayProbe(),
      ),
      controlPlaneProbeProvider.overrideWithValue(
        controlProbe ?? DownControlProbe(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<(ProviderContainer, FakeTunnel)> seedConnected(
  List<String> events,
  dynamic Function(RequestOptions options) respond, {
  List<Keypair> keyQueue = const [],
  Clock? clock,
  GatewayProbe? gatewayProbe,
  ControlPlaneProbe? controlProbe,
  bool expectConnected = true,
}) async {
  final store = FakeStore();
  final keys = FakeKeys(List.of(keyQueue));
  final api = VpnApi(recordingDio(events, respond));
  final tunnel = FakeTunnel(events);
  final container = makeContainer(
    store: store,
    keys: keys,
    api: api,
    clock: clock,
    gatewayProbe: gatewayProbe,
    controlProbe: controlProbe,
  );
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  // Fresh handshake by default: individual tests override with a stale one
  // to drive heals. Fresh means live rekeys, so nothing heals unprompted.
  ctl.debugHandshakeReader = () async => DateTime.now();
  await ctl.connect();
  // A connect that is expected to fail (a region this build cannot serve) has
  // its own assertions; the phase is not `connected` for it.
  if (expectConnected) {
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  }
  events.clear();
  return (container, tunnel);
}

/// Points the controller's handshake read just past the 150s rekey window
/// (so it corroborates normally) but safely below
/// [ConnectionTuning.hardHandshakeStaleAfter], so the backend-corroboration
/// gate still applies.
void staleHandshake(ConnectionController ctl) {
  ctl.debugHandshakeReader = () async => DateTime.now().subtract(
    ConnectionTuning.handshakeStaleAfter + const Duration(seconds: 10),
  );
}

/// Points the controller's handshake read past the hard ceiling: the peer
/// has missed multiple rekey cycles, so the handshake alone drives recovery.
void hardStaleHandshake(ConnectionController ctl) {
  ctl.debugHandshakeReader = () async => DateTime.now().subtract(
    ConnectionTuning.hardHandshakeStaleAfter + const Duration(seconds: 1),
  );
}

void main() {
  List<Map<String, dynamic>> twoServers() => [
    {
      'id': 'srv-1',
      'name': 'one',
      'endpoint': '203.0.113.10',
      'wg_port': 51820,
      'wg_dns': '10.8.0.1',
      'wg_public_key': 'SRV',
      'active_peers': 9,
    },
    {
      'id': 'srv-2',
      'name': 'two',
      'endpoint': '203.0.113.11',
      'wg_port': 51820,
      'wg_dns': '10.8.0.1',
      'wg_public_key': 'SRV2',
      'active_peers': 1,
    },
  ];

  List<Map<String, dynamic>> regionsList(List<Map<String, dynamic>> servers) =>
      [
        {'id': 'r1', 'name': 'R1', 'country_code': null, 'servers': servers},
      ];

  /// The second node of [twoServers] as a dial payload — a stock-only node, so
  /// its ladder is `native` alone.
  Map<String, dynamic> dialJsonSrv2() => dialJson(
    serverId: 'srv-2',
    serverName: 'two',
    assignedIp: '10.8.0.6',
    endpoint: '203.0.113.11',
    wgPublicKey: 'SRV2',
  );

  test(
    'repeated transient polls raise a degraded banner, stay connected',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      });
      final ctl = container.read(connectionProvider.notifier);

      await ctl.pollStatusOnce();
      await ctl.pollStatusOnce();
      var state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.pollFailures, 2);
      expect(state.healthNote, isNull);

      await ctl.pollStatusOnce();
      state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.pollFailures, 3);
      expect(state.healthNote, contains('Backend unreachable'));
      // Tunnel untouched by backend trouble.
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
    },
  );

  test('successful poll clears the failure count and outage budgets', () async {
    final events = <String>[];
    var fail = true;
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        if (fail) throw networkTimeout(o);
        return activeStatusJson();
      }
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    // Budgets accrued during an outage must all clear when the backend
    // comes back — heal included (it used to survive the poll and keep
    // escalating the next outage prematurely).
    ctl.snap = ctl.snap.copyWith(autoHealAttempts: 2, autoFailoverAttempts: 3);

    await ctl.pollStatusOnce();
    await ctl.pollStatusOnce();
    await ctl.pollStatusOnce();
    expect(container.read(connectionProvider).healthNote, contains('Backend'));

    fail = false;
    await ctl.pollStatusOnce();
    final state = container.read(connectionProvider);
    expect(state.pollFailures, 0);
    expect(state.healthNote, isNull);
    expect(state.lastStatusAt, isNotNull);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
  });

  test('spent failover budget does not loop local healing', () async {
    // Failover budget already spent: one local restart is enough; subsequent
    // ticks must wait instead of restarting the same-server config again.
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    ctl.snap = ctl.snap.copyWith(autoFailoverAttempts: 3);
    staleHandshake(ctl);

    // Cycle 1: first corroborated stall heals offline on the cached config.
    await ctl.pollStatusOnce();
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    var state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
    events.clear();

    // Cycle 2: the failover budget is spent, so the next stall waits. No
    // regions discovery or second local restart may run.
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(state.autoFailoverAttempts, 3);
    expect(events, isNot(contains('GET:/vpn-regions')));
  });

  test(
    'exhausted ladder stops looping and surfaces an actionable error',
    () async {
      // Move budget spent and the trailing same-server restarts did not fix
      // it: recovery must not restart the proven-dead config forever. It
      // stops the tunnel and hands the user an explicit retry instead.
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }, controlProbe: support.FakeControlProbe(true));
      final ctl = container.read(connectionProvider.notifier);
      ctl.snap = ctl.snap.copyWith(autoFailoverAttempts: 3);
      staleHandshake(ctl);

      // One bounded heal is allowed after the move budget is spent.
      for (var i = 0; i < ConnectionTuning.maxHealsAfterMoveBudget; i++) {
        await ctl.pollStatusOnce();
        await ctl.checkHealthOnce();
      }
      var state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, ConnectionTuning.maxHealsAfterMoveBudget);

      // The next corroborated stall has nothing left to try.
      await ctl.pollStatusOnce();
      await ctl.checkHealthOnce();

      state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.error);
      expect(state.message, contains('Automatic recovery failed'));
      expect(state.lastStage, isNull);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 0);
      // The dead tunnel is down and never restarted.
      final tunnelEvents = events
          .where((e) => e.startsWith('tunnel:'))
          .toList();
      expect(tunnelEvents, isNotEmpty);
      expect(tunnelEvents.last, 'tunnel:stop');
    },
  );

  test('degraded stage plus a poll failure triggers auto-heal', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    tunnel.stageValue = VpnStage.noConnection;
    tunnel.traffic = const {'rx': 7};

    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(events, contains('tunnel:start'));
  });

  test('stall heals offline on the cached config', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    events.clear();

    // Stale handshake, backend never polled (outage before the first poll):
    // the quiet slow-track corroborates without any poll failure.
    staleHandshake(ctl);
    await ctl.checkHealthOnce();

    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(state.message, 'Connected');
  });

  // The transport ladder. Every rung below the floor is a *response* to a dead
  // tunnel path with a reachable control plane, so these cases explicitly choose
  // the probes and platform they exercise — a host-platform default would
  // otherwise change which rungs this build can even start.
  group('transport ladder', () {
    void useLinuxDataPlane() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    }

    /// A node serving stock *and* obfuscated, which is the shape every server has
    /// now that `awg_enabled` defaults on: one device per rung, each on its own
    /// port and its own overlay.
    Map<String, dynamic> dualDial() => dialJson(awgPort: 51821);

    /// Heals once and re-arms the heal budget, so a suite can walk the ladder
    /// one rung per incident the way separate outages would. The cap is what
    /// makes each rung its own incident; re-arming between steps is what a
    /// second outage does on its own.
    Future<void> stepDown(ProviderContainer container) async {
      final ctl = container.read(connectionProvider.notifier);
      staleHandshake(ctl);
      await ctl.checkHealthOnce();
      ctl.snap = ctl.snap.copyWith(autoHealAttempts: 0);
      ctl.debugHandshakeReader = () async => DateTime.now();
    }

    Future<(ProviderContainer, FakeTunnel)> seedDual() {
      final events = <String>[];
      return seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dualDial();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      });
    }

    test('a dual-format node starts on its cheapest rung, native', () async {
      useLinuxDataPlane();
      final (container, tunnel) = await seedDual();

      // The floor is the cheapest rung the node advertises *and* this platform
      // can run — scoped to what the node offers, not to what this build could
      // run in general. Native is advertised by every node, so it is the floor
      // everywhere, including on a platform with no obfuscated data plane. A
      // stock start is not a cheap probe but the node's own stock device, reached
      // on its own port, so it costs nothing on an unobstructed network.
      expect(tunnel.configs.first, isNot(contains('Jc =')));
      expect(tunnel.configs.first, contains('Endpoint = 203.0.113.10:51820'));
      expect(
        container.read(connectionProvider.notifier).transportRung,
        TransportRung.native,
      );
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
    });

    test('Android starts a dual-format node on native too', () async {
      // The floor rule reads the advertised list, not the platform's abilities
      // in the abstract. Android can run the awg data plane, but `native` is
      // cheaper and offered, so the awg rung is only ever reached by demotion.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (container, tunnel) = await seedDual();

      expect(tunnel.configs.first, isNot(contains('Jc =')));
      expect(
        container.read(connectionProvider.notifier).transportRung,
        TransportRung.native,
      );
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
    });

    test(
      'a confirmed dead path steps to the obfuscated rung with its parameters',
      () async {
        useLinuxDataPlane();
        final (container, tunnel) = await seedConnected(<String>[], (o) {
          if (o.path.endsWith('/config')) return dualDial();
          if (o.path.endsWith('/status')) throw networkTimeout(o);
          throw StateError('unexpected ${o.path}');
        }, controlProbe: support.FakeControlProbe(true));
        final ctl = container.read(connectionProvider.notifier);

        staleHandshake(ctl);
        await ctl.checkHealthOnce();

        // One rung down, carrying that rung's own port and the full parameter
        // set verbatim, between DNS and [Peer] (see buildWgQuickConfig).
        expect(ctl.transportRung, TransportRung.awg);
        expect(tunnel.lastConfig, contains('Endpoint = 203.0.113.10:51821'));
        expect(tunnel.lastConfig, isNot(contains('ListenPort = ')));
        expect(
          tunnel.lastConfig,
          contains(
            'Jc = 3\n'
            'Jmin = 40\n'
            'Jmax = 70\n'
            'S1 = 15\n'
            'S2 = 17\n'
            'S3 = 10\n'
            'S4 = 5\n'
            'H1 = 115-120\n'
            'H2 = 130-130\n'
            'H3 = 150-160\n'
            'H4 = 171-171',
          ),
        );
        final state = container.read(connectionProvider);
        expect(state.autoHealAttempts, 1);
        expect(state.phase, ConnPhase.connected);
      },
    );

    test('a blackout restart stays on the current rung', () async {
      useLinuxDataPlane();
      final (container, tunnel) = await seedDual();
      final ctl = container.read(connectionProvider.notifier);

      // No control plane (the seeded default), so a dead path cannot tell
      // "this transport is blocked" from "the network is gone". The heal
      // rebuilds; the rung must not move.
      staleHandshake(ctl);
      await ctl.checkHealthOnce();

      expect(ctl.transportRung, TransportRung.native);
      expect(tunnel.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
      expect(tunnel.lastConfig, isNot(contains('Jc =')));
      expect(container.read(connectionProvider).autoHealAttempts, 1);
    });

    test('a node offering no obfuscated rung never obfuscates', () async {
      useLinuxDataPlane();
      final events = <String>[];
      final (container, tunnel) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }, controlProbe: support.FakeControlProbe(true));
      final ctl = container.read(connectionProvider.notifier);

      final before = tunnel.configs.length;
      await stepDown(container);

      // The heal still happened — the ladder adds rungs, it does not replace
      // the one a node already serves. Counted from the confs rather than the
      // heal counter, which [stepDown] re-arms between incidents.
      expect(tunnel.configs.length, before + 1);
      expect(ctl.transportRung, TransportRung.native);
      expect(tunnel.lastConfig, isNot(contains('Jc =')));
    });

    test('a platform without the data plane starts native and stays there', () async {
      // Fuchsia has no obfuscated data plane, so the awg rung is not runnable
      // here — but that no longer makes the node unreachable. Every node
      // advertises its stock device, so the start succeeds and the rung simply
      // never appears on the ladder.
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (container, tunnel) = await seedDual();
      final ctl = container.read(connectionProvider.notifier);

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(tunnel.configs.first, contains('Endpoint = 203.0.113.10:51820'));
      expect(ctl.transportRung, TransportRung.native);

      // And a confirmed dead path has nowhere to step to, so it rebuilds in
      // place rather than selecting a rung this build cannot start.
      (container.read(
        controlPlaneProbeProvider,
      ) as support.FakeControlProbe).reachable = true;
      await stepDown(container);
      expect(ctl.transportRung, TransportRung.native);
      expect(tunnel.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
    });

    test('a payload with no usable rung is refused, not guessed at', () async {
      // The one thing `_applyRung` still refuses: a list with nothing in it this
      // build can start. There is no entry to build a conf from, so any start
      // would be a guess at what the node runs.
      final events = <String>[];
      final (container, tunnel) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) {
          final dial = dialJson()..['transports'] = <Map<String, Object>>[];
          return dial;
        }
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }, expectConnected: false);

      expect(container.read(connectionProvider).phase, ConnPhase.error);
      expect(
        container.read(connectionProvider).message,
        contains('offers no transport'),
      );
      expect(tunnel.configs, isEmpty);
    });

    test('demotion is sticky: a later manual connect stays on the lower rung', () async {
      useLinuxDataPlane();
      final (container, tunnel) = await seedConnected(<String>[], (o) {
        if (o.path.endsWith('/config')) return dualDial();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      }, controlProbe: support.FakeControlProbe(true));
      final ctl = container.read(connectionProvider.notifier);

      await stepDown(container);
      expect(ctl.transportRung, TransportRung.awg);

      // Arm a fresh handshake for the reconnected session so the test observes
      // the conf the connect builds, not a follow-on recovery cycle racing the
      // assertion.
      ctl.debugHandshakeReader = () async => DateTime.now();
      await ctl.disconnect();
      await ctl.connect();

      // One proven-blocked network re-pays the failed-probe cycle on every
      // connect; the process stays on the rung it demoted to. Note this is not
      // the node's floor — the node still advertises native — which is exactly
      // what sticky means.
      expect(tunnel.lastConfig, contains('Jc = 3'));
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(container.read(connectionProvider).autoHealAttempts, 0);
    });

    group('stream rung', () {
      // The stream rung is the last one, so these start from a node offering the
      // whole ladder and walk all the way down — which is the only way to prove
      // the walk visits stream at all rather than skipping over it.
      Map<String, dynamic> streamDial({
        String serverId = 'srv-1',
        String serverName = 'one',
        String endpoint = '203.0.113.10',
        String wgPublicKey = 'SRV',
      }) => dialJson(
        serverId: serverId,
        serverName: serverName,
        endpoint: endpoint,
        wgPublicKey: wgPublicKey,
        awgPort: 51821,
        stream: streamTransportJson(),
      );

      /// [dialJson] with the stream credential but no obfuscated rung: a node
      /// whose only rung below native is the stream transport.
      Map<String, dynamic> streamOnlyDial() =>
          dialJson(stream: streamTransportJson());

      /// The stream rung only ever runs through the privileged helper, so these
      /// suites drive [HelperTunnelAdapter] over a fake socket rather than the
      /// plugin adapter the rest of the file uses. That is also what makes the
      /// capability gate testable for real: the tokens come from the socket's
      /// responses, exactly as they come from a daemon's `ping`.
      Future<(ProviderContainer, FakeHelperSocket)> seedStream({
        Set<String>? caps,
        Map<String, dynamic> Function()? dial,
        Map<String, dynamic> Function()? onSwitch,
        List<Map<String, dynamic>> Function()? onRegions,
        GatewayProbe? gatewayProbe,
        ControlPlaneProbe? controlProbe,
        Clock? clock,
        bool expectConnected = true,
      }) async {
        final events = <String>[];
        final socket = FakeHelperSocket()..caps = caps ?? {capStreamTransport};
        final store = FakeStore();
        final api = VpnApi(
          recordingDio(events, (o) {
            if (o.path.endsWith('/config')) return (dial ?? streamDial)();
            if (o.path.endsWith('/switch')) return (onSwitch ?? streamDial)();
            if (o.path.endsWith('/vpn-regions')) {
              if (onRegions != null) return onRegions();
            }
            if (o.path.endsWith('/status')) throw networkTimeout(o);
            throw StateError('unexpected ${o.path}');
          }),
        );
        final container = makeContainer(
          store: store,
          // A switch binds a fresh peer, so the key manager has to be able to
          // generate; the connect path reuses the stored identity.
          keys: FakeKeys(),
          api: api,
          clock: clock,
          gatewayProbe: gatewayProbe,
          controlProbe: controlProbe,
          tunnel: HelperTunnelAdapter(client: HelperClient(socket: socket)),
        );
        await store.setDeviceId('dev-1');
        await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
        final ctl = container.read(connectionProvider.notifier);
        ctl.debugHandshakeReader = () async => DateTime.now();
        await ctl.connect();
        if (expectConnected) {
          expect(container.read(connectionProvider).phase, ConnPhase.connected);
        }
        events.clear();
        return (container, socket);
      }

      /// Walks the ladder down to [target], one rung per healed incident.
      Future<void> stepDownTo(
        ProviderContainer container,
        TransportRung target,
      ) async {
        final ctl = container.read(connectionProvider.notifier);
        while (ctl.transportRung.index < target.index) {
          await stepDown(container);
        }
      }

      test('a node offering the whole ladder starts on native', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream();

        // The stream rung is the most expensive and is only reached on evidence,
        // so the first start points straight at the node's stock device on its
        // own port with a stock body.
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
        expect(socket.lastTransport, isNull);
        expect(
          container.read(connectionProvider.notifier).transportRung,
          TransportRung.native,
        );
      });

      test('Android also starts a dual-format node on native', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final (container, socket) = await seedStream();

        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
        expect(socket.lastTransport, isNull);
        expect(
          container.read(connectionProvider.notifier).transportRung,
          TransportRung.native,
        );
      });

      test('a confirmed dead path steps the ladder before spending a move', () async {
        // The production-timing case, and the one that used to fail. A
        // confirmed dead echo (`echoShortens` latched at 2 strikes) plus a
        // stale handshake used to fast-track straight to failover, because
        // Layer 1 cannot tell a blocked transport from a dead node. The heal
        // now takes the rung step first; only a stall that survives it
        // escalates to a server move.
        //
        // Two ticks are required, and the first must be the one that banks a
        // strike: `echoProbeAfter` = 30s opens the probe window long before
        // `handshakeStaleAfter` = 150s makes a heal eligible, so in
        // production `echoStallStrikes` = 2 is always already satisfied by
        // the time the ladder becomes reachable. A single-tick test cannot
        // cover that.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        // Tick 1: old enough to probe (>= 30s) but not stale enough to act.
        // Banks strike 1 and returns without healing, so nothing resets it.
        ctl.debugHandshakeReader = () async =>
            DateTime.now().subtract(const Duration(seconds: 40));
        await ctl.checkHealthOnce();
        expect(ctl.transportRung, TransportRung.native);

        // Tick 2: same as `staleHandshake`, now with strikes at 2. The step is
        // to the rung immediately below — awg, the node's second device — so
        // the first step is what this asserts, not the bottom of the ladder.
        staleHandshake(ctl);
        await ctl.checkHealthOnce();

        expect(ctl.transportRung, TransportRung.awg);
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51821'));
        expect(socket.lastConfig, contains('Jc = 3'));
        expect(socket.lastTransport, isNull);

        final state = container.read(connectionProvider);
        expect(state.phase, ConnPhase.connected);
        expect(state.dial?.serverId, 'srv-1');
        expect(state.autoHealAttempts, 1);
        expect(state.autoFailoverAttempts, 0);
        expect(state.recoveryAction, RecoveryAction.tryingAwg);
        expect(state.recoveryReason, RecoveryReason.gatewayUnreachable);
        expect(state.recoveryDetail, contains('echo dead'));
      });

      test('the walk reaches the stream rung on a second incident', () async {
        // One rung per incident, because the heal budget is what buys the step
        // and it is one restart per incident by design. The second step is where
        // the inner format inverts: the node's bridge injects into its *stock*
        // device, so a stream session carries stock datagrams whatever the node
        // also serves. An obfuscated conf inside the TLS session would reach a
        // device that does not speak them.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDownTo(container, TransportRung.stream);

        expect(ctl.transportRung, TransportRung.stream);
        expect(socket.lastConfig, contains('Endpoint = 127.0.0.1:'));
        expect(socket.lastConfig, contains('ListenPort = '));
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastTransport, isNotNull);
      });

      test('a backend-confirmed dead node moves servers without stepping a rung', () async {
        // The rungs exist for a transport the network blocks; a node the
        // backend has given up on is not that. So the ladder is skipped even
        // though this node serves one below — the `!serverDown` half of the
        // rung-step gate, which no stock-node suite can reach.
        //
        // `serverConfirmedDown` is normally the status poll's verdict (see the
        // poll suite); seeding it keeps this row about the ladder decision.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
          onRegions: () => regionsList(twoServers()),
          onSwitch: () => streamDial(
            serverId: 'srv-2',
            serverName: 'two',
            endpoint: '203.0.113.11',
            wgPublicKey: 'SRV2',
          ),
        );
        final ctl = container.read(connectionProvider.notifier);
        ctl.snap = ctl.snap.copyWith(serverConfirmedDown: true);
        ctl.debugHandshakeReader = () async => DateTime.now().subtract(
          ConnectionTuning.handshakeStaleAfter + const Duration(seconds: 10),
        );

        await ctl.checkHealthOnce();

        final state = container.read(connectionProvider);
        expect(ctl.transportRung, TransportRung.native);
        // No heal is spent and no rung step happens: the heal budget is not
        // what this stall needs.
        expect(state.autoHealAttempts, 0);
        expect(state.autoFailoverAttempts, 1);
        expect(state.dial?.serverId, 'srv-2');
        expect(state.recoveryAction, RecoveryAction.switchingServer);
        expect(state.recoveryReason, RecoveryReason.serverOffline);
        // The move kept the rung, and the new node advertises it.
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.11:51820'));
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastTransport, isNull);
      });

      test('a never-completed handshake with the control plane up steps a rung', () async {
        // The gap this closes. A first connect whose handshake never completes
        // is the classic blocked-UDP signature — the API answers while the
        // tunnel's own path does not — but it used to spend its single heal on
        // a same-rung restart, and the uncorroborated ceiling arrived after
        // that budget was gone, so the ladder could only fast-track to another
        // server: a rung step was unreachable for this case.
        //
        // The echo is unprobeable on purpose (`wg_dns` yields no target). A
        // performed-dead echo would carry the same information through the
        // echo's own rule and hide whether this verdict is what acted.
        useLinuxDataPlane();
        final clock = support.FakeClock();
        final (container, socket) = await seedStream(
          clock: clock,
          gatewayProbe: support.FakeGatewayProbe(null),
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);
        // A real reader reporting no handshake yet, ever.
        ctl.debugHandshakeReader = () async => null;
        clock.advance(ConnectionTuning.firstHandshakeGrace);

        await ctl.checkHealthOnce();

        // The same heal, spent on the rung instead of a pointless rebuild: the
        // node advertises a rung below, and no server was touched.
        expect(ctl.transportRung, TransportRung.awg);
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51821'));
        expect(socket.lastConfig, contains('Jc = 3'));
        expect(socket.lastTransport, isNull);
        final state = container.read(connectionProvider);
        expect(state.autoHealAttempts, 1);
        expect(state.autoFailoverAttempts, 0);
        expect(state.dial?.serverId, 'srv-1');
        expect(state.recoveryAction, RecoveryAction.tryingAwg);
        expect(state.recoveryReason, RecoveryReason.staleHandshake);
        expect(state.recoveryDetail, contains('never completed'));
      });

      test('a long-healthy session probes one cheaper rung', () async {
        useLinuxDataPlane();
        final clock = support.FakeClock();
        final controlProbe = support.FakeControlProbe(true);
        final (container, socket) = await seedStream(
          clock: clock,
          controlProbe: controlProbe,
        );
        final ctl = container.read(connectionProvider.notifier);
        ctl.debugHandshakeReader = () async => clock.now().subtract(
          ConnectionTuning.handshakeStaleAfter + const Duration(seconds: 10),
        );
        await ctl.checkHealthOnce();
        expect(ctl.transportRung, TransportRung.awg);
        ctl.snap = ctl.snap.copyWith(autoHealAttempts: 0);

        ctl.debugHandshakeReader = () async => clock.now();

        clock.advance(ConnectionTuning.rungPromotionHealthyFor);
        await ctl.checkHealthOnce();

        // The probe is one step only: awg -> native, on the stock port and with
        // a stock body. Because the floor is the node's own cheapest rung, a
        // probe can never be a no-op that rebuilds the identical conf — the
        // candidate always carries a different port and format.
        expect(ctl.transportRung, TransportRung.native);
        expect(
          container.read(connectionProvider).recoveryAction,
          RecoveryAction.tryingNative,
        );
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastTransport, isNull);

        // A fresh handshake on the candidate confirms it. A later outage must
        // not revert to the expensive rung as though this probe had failed.
        ctl.debugHandshakeReader = () async => clock.now();
        await ctl.checkHealthOnce();
        ctl.debugHandshakeReader = () async => null;
        controlProbe.reachable = false;
        clock.advance(ConnectionTuning.rungPromotionProbeTimeout);
        await ctl.checkHealthOnce();
        expect(ctl.transportRung, TransportRung.native);
      });

      test(
        'a cheaper-rung probe without liveness rolls back quickly',
        () async {
          useLinuxDataPlane();
          final clock = support.FakeClock();
          final controlProbe = support.FakeControlProbe(true);
          final (container, socket) = await seedStream(
            clock: clock,
            controlProbe: controlProbe,
          );
          final ctl = container.read(connectionProvider.notifier);
          ctl.debugHandshakeReader = () async => clock.now().subtract(
            ConnectionTuning.handshakeStaleAfter + const Duration(seconds: 10),
          );
          await ctl.checkHealthOnce();
          expect(ctl.transportRung, TransportRung.awg);
          ctl.snap = ctl.snap.copyWith(autoHealAttempts: 0);

          ctl.debugHandshakeReader = () async => clock.now();

          clock.advance(ConnectionTuning.rungPromotionHealthyFor);
          await ctl.checkHealthOnce();
          expect(ctl.transportRung, TransportRung.native);

          ctl.debugHandshakeReader = () async => null;
          controlProbe.reachable = false;
          clock.advance(ConnectionTuning.rungPromotionProbeTimeout);
          await ctl.checkHealthOnce();

          expect(ctl.transportRung, TransportRung.awg);
          expect(
            container.read(connectionProvider).recoveryAction,
            RecoveryAction.tryingAwg,
          );
          expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51821'));
          expect(socket.lastConfig, contains('Jc = 3'));
          expect(socket.lastTransport, isNull);
        },
      );

      test(
        'the rung step is bounded by the heal budget, then moves servers',
        () async {
          // The other half of the contract: the ladder buys exactly one step,
          // spent from the heal budget that already existed. Once that budget
          // is spent, a confirmed dead path moves servers instead — so the
          // ladder trades a move budget for a rung rather than granting an
          // unbounded retry on the same rung.
          //
          // The budget is spent in-session rather than by healing first: a
          // reconnect resets it by design, so waiting for a real heal to spend
          // it would test the reset instead of the bound.
          useLinuxDataPlane();
          final (container, socket) = await seedStream(
            controlProbe: support.FakeControlProbe(true),
          );
          final ctl = container.read(connectionProvider.notifier);
          ctl.snap = ctl.snap.copyWith(autoHealAttempts: 1);

          // Bank strike 1 on a handshake too fresh to act on.
          ctl.debugHandshakeReader = () async =>
              DateTime.now().subtract(const Duration(seconds: 40));
          await ctl.checkHealthOnce();

          // Strike 2 makes the path confirmed-dead. `canHeal` is now false, so
          // `rungStepAvailable` is false too and the evidence fast-tracks.
          staleHandshake(ctl);
          await ctl.checkHealthOnce();

          // No rung step: the budget was spent, so the evidence moved servers
          // instead. `autoHealAttempts` is not asserted — the fallback restart
          // re-asserts it to 0 by design (conn_recovery.dart:753).
          final state = container.read(connectionProvider);
          expect(ctl.transportRung, TransportRung.native);
          expect(socket.lastTransport, isNull);
          expect(state.autoFailoverAttempts, 1);
        },
      );

      test(
        'a node with no lower rung keeps the old move-first escalation',
        () async {
          // The fix is scoped by whether a rung actually exists below. A
          // stock-only node serves nothing but native, so there is nowhere to
          // step and a confirmed dead path must still go straight to failover:
          // a heal would rebuild the same config on the same rung, so spending
          // the heal budget in place of the move would only delay recovery.
          final events = <String>[];
          final (container, _) = await seedConnected(
            events,
            (o) {
              if (o.path.endsWith('/config')) return dialJson();
              if (o.path.endsWith('/status')) throw networkTimeout(o);
              if (o.path.endsWith('/vpn-regions')) {
                return regionsList(twoServers());
              }
              if (o.path.endsWith('/switch')) return dialJsonSrv2();
              throw StateError('unexpected ${o.path}');
            },
            // A switch binds a fresh peer, so the move needs a keypair to
            // generate; without one it falls back to bouncing the same dial.
            keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
          );
          final ctl = container.read(connectionProvider.notifier);

          // Bank strike 1 on a handshake too fresh to act on, so the budget is
          // still whole when the path becomes confirmed-dead on the next tick.
          ctl.debugHandshakeReader = () async =>
              DateTime.now().subtract(const Duration(seconds: 40));
          await ctl.checkHealthOnce();
          expect(container.read(connectionProvider).autoHealAttempts, 0);

          staleHandshake(ctl);
          await ctl.checkHealthOnce();

          final state = container.read(connectionProvider);
          expect(state.phase, ConnPhase.connected);
          expect(state.autoHealAttempts, 0);
          expect(state.autoFailoverAttempts, 1);
          expect(state.dial?.serverId, 'srv-2');
        },
      );

      test('an unprobeable echo rebuilds without spending a rung', () async {
        // The distinction the ladder is graded by. A null echo is *unknown*, not
        // dead, so nothing here fast-tracks and the heal runs — but a stale
        // handshake alone is not `tunnelPathDead` either, so the rung stays put
        // and the rebuild is on the current rung. Only a positively dead path
        // while the control plane answers buys a rung (the rows above), because
        // that is the one signature of a blocked transport rather than a busy or
        // unprobeable network.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        (container.read(
          gatewayProbeProvider,
        ) as support.FakeGatewayProbe).alive = null;

        // A second tick with a fresh handshake in between, so this cannot pass
        // merely by being the first one after the connect.
        await stepDown(container);
        staleHandshake(ctl);
        await ctl.checkHealthOnce();

        expect(ctl.transportRung, TransportRung.native);
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastTransport, isNull);
        expect(container.read(connectionProvider).autoHealAttempts, 1);
      });

      test('the bridge receives the transport spec on the stream rung', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDownTo(container, TransportRung.stream);

        // The spec the helper receives is what makes the bridge real: the
        // credential passes through from the control plane, and the two
        // loopback addresses are this client's contribution, agreeing with
        // the conf the same start built.
        final spec = socket.lastTransport;
        expect(spec, isNotNull);
        expect(spec!['mode'], 'stream');
        expect(spec['server'], 'vpn.example.net:443');
        expect(spec['server_name'], 'vpn.example.net');
        expect(spec['psk'], isNotEmpty);
        expect(spec['listen'], isNot(spec['deliver']));

        // The conf the same start built has to agree with the spec, or the
        // tunnel's peer endpoint and the bridge's listener would be different
        // addresses and nothing would ever handshake.
        final listen = spec['listen'] as String;
        final deliverPort = (spec['deliver'] as String).split(':').last;
        expect(socket.lastConfig, contains('Endpoint = $listen'));
        expect(socket.lastConfig, contains('ListenPort = $deliverPort'));
        // And the tunnel the bridge carries is *stock*, whatever this node also
        // serves. The node's bridge injects into its stock device, so a
        // session's datagrams have to be stock to be readable there; applying
        // the awg directives would hand an obfuscated conf to a device that
        // does not speak them. This is the inversion from the single-device
        // node, whose only tunnel was the AmneziaWG one.
        expect(socket.lastConfig, isNot(contains('Jc =')));
        // Which is also why the stock overlay's address and resolver are the
        // right ones here, not the obfuscated pair the awg rung claims.
        expect(socket.lastConfig, contains('Address = 10.8.0.5/32'));
        expect(socket.lastConfig, contains('DNS = 10.8.0.1'));
        // Which the branch below reads the rung off, so it is not dead.
        expect(ctl.transportRung, TransportRung.stream);
      });

      // The port a rung is reached on is the property most easily lost in a
      // refactor and most expensive when it is: a client that dialled wg_port on
      // the awg rung would put a plaintext WireGuard handshake on the wire first
      // — the exact fingerprint the rung exists to hide — and then fail to
      // connect, which reads to the health ladder as a blocked network rather
      // than a wrong port.
      test('the awg rung dials the obfuscated port, never wg_port', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDown(container);

        expect(socket.lastConfig, contains('Jc = 3'));
        expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51821'));
        expect(
          socket.lastConfig,
          isNot(contains('Endpoint = 203.0.113.10:51820')),
        );
        expect(ctl.transportRung, TransportRung.awg);
      });

      // The awg rung needs an address on the node's obfuscated overlay as well as
      // the rung's own port and parameters. A payload missing the address is
      // asking for a conf whose every packet the node cannot route — a tunnel
      // that handshakes and then goes nowhere, which reads to the ladder as a
      // blocked network and demotes the rung that was working. So the rung is
      // treated as not offered, and the walk skips straight past it.
      test('a node offering no obfuscated address does not offer the rung', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          dial: () => dialJson(
            awgPort: 51821,
            // No address on the obfuscated overlay: the field absent, which is
            // what a node claiming the rung without one sends.
            awgAssignedIp: '',
            stream: streamTransportJson(),
          ),
          // Reachable control plane, so the heal below reads as "this transport
          // is blocked" and steps the ladder rather than moving servers.
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        // It starts on native, and the awg rung is not on the ladder at all, so
        // the single step below lands on the stream rung.
        await stepDown(container);

        expect(ctl.transportRung, TransportRung.stream);
        expect(socket.lastConfig, contains('Endpoint = 127.0.0.1:'));
        expect(socket.lastConfig, isNot(contains('Jc =')));
        expect(socket.lastConfig, contains('Address = 10.8.0.5/32'));
        expect(socket.lastTransport, isNotNull);
      });

      // The counterpart: with the address present, the awg rung claims *it* and
      // not the stock one. Getting this backwards produces a tunnel that
      // handshakes and then blackholes every packet, because the obfuscated
      // device has no route to a stock address.
      test('the awg rung claims the obfuscated overlay address', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDown(container);

        expect(socket.lastConfig, contains('Address = 10.9.0.5/32'));
        expect(socket.lastConfig, contains('DNS = 10.9.0.1'));
        expect(socket.lastConfig, isNot(contains('Address = 10.8.0.5/32')));
        expect(ctl.transportRung, TransportRung.awg);
      });

      // The mirror on a dual-format node is the stream case above: it asserts
      // the stock address and resolver there, on a node that *does* carry the
      // obfuscated pair, which is the assertion that catches a conf picking the
      // wrong overlay. The native rung needs no suite of its own — every node
      // serves it, and every native suite already asserts the stock address.

      test(
        'a node offering only the stream credential reaches it in one step',
        () async {
          useLinuxDataPlane();
          // No obfuscated rung at all, so the walk has nowhere to go but stream
          // on the *first* heal.
          final (container, socket) = await seedStream(
            dial: streamOnlyDial,
            controlProbe: support.FakeControlProbe(true),
          );

          await stepDown(container);

          expect(socket.lastConfig, contains('Endpoint = 127.0.0.1:'));
          // The node's bridge injects into its stock device, so the stream
          // carries stock datagrams: no obfuscation directives.
          expect(socket.lastConfig, isNot(contains('Jc =')));
          expect(socket.lastTransport, isNotNull);
          expect(
            container.read(connectionProvider.notifier).transportRung,
            TransportRung.stream,
          );
        },
      );

      test('a daemon without the capability never offers the stream rung', () async {
        // An older Linux helper knows nothing about transports, so its missing
        // token has to keep the rung off the ladder entirely — while leaving the
        // rungs it *can* serve alone.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          caps: const {},
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDown(container);
        staleHandshake(ctl);
        await ctl.checkHealthOnce();

        expect(socket.lastConfig, contains('Jc = 3'));
        expect(socket.lastConfig, isNot(contains('Endpoint = 127.0.0.1:')));
        expect(ctl.transportRung, TransportRung.awg);
      });

      test(
        'a platform without either data plane starts native and stops',
        () async {
          // Fuchsia has neither an obfuscated data plane nor the stream bridge, so
          // the only rung it can run is the node's stock device. It connects there
          // rather than refusing — which is the whole point of the floor rule
          // being scoped to the advertised list.
          debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final (container, socket) = await seedStream();

          expect(container.read(connectionProvider).phase, ConnPhase.connected);
          expect(socket.lastConfig, contains('Endpoint = 203.0.113.10:51820'));
          expect(socket.lastConfig, isNot(contains('Jc =')));
          expect(socket.lastTransport, isNull);
          expect(
            container.read(connectionProvider.notifier).transportRung,
            TransportRung.native,
          );
        },
      );

      test('the walk stops at the last rung rather than inventing one', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDownTo(container, TransportRung.stream);

        // One more incident on the bottom rung. There is nothing below stream,
        // so the rung must not move and the rebuild must stay a stream rebuild —
        // this is where a missing `null` case would invent a fourth rung.
        await stepDown(container);

        expect(ctl.transportRung, TransportRung.stream);
        expect(socket.lastConfig, contains('Endpoint = 127.0.0.1:'));
        expect(socket.lastTransport, isNotNull);
      });

      test('a move to a node with no stream credential drops the rung', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
          // The move lands on a stock node whose dial carries no stream
          // credential, so the sticky stream rung has nothing to run there.
          onSwitch: () => dialJson(serverId: 'srv-2', serverName: 'two'),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDownTo(container, TransportRung.stream);
        expect(ctl.transportRung, TransportRung.stream);

        await ctl.switchServer(regionId: null, serverId: 'srv-2');

        // Keeping the stream rung would only throw — there is no credential to
        // build a bridge from — so the start drops to the new node's floor:
        // native, the only rung a stock node serves.
        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        expect(ctl.transportRung, TransportRung.native);
        expect(socket.lastTransport, isNull);
        expect(socket.lastConfig, isNot(contains('Endpoint = 127.0.0.1:')));
      });

      test('a move onto a dual-format node keeps the sticky rung', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDownTo(container, TransportRung.stream);

        // The new node advertises the whole ladder, so a sticky rung it also
        // serves is kept — a server move must not silently pay for the walk
        // again. This is the rung floor never re-probing on a move.
        await ctl.switchServer(regionId: null, serverId: 'srv-1');
        await ctl.switchServer(regionId: null, serverId: 'srv-2');

        expect(container.read(connectionProvider).phase, ConnPhase.connected);
        expect(ctl.transportRung, TransportRung.stream);
        expect(socket.lastTransport, isNotNull);
      });

      test('a node without a stream credential never demotes to it', () async {
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          dial: () => dialJson(awgPort: 51821),
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDown(container);
        await stepDown(container);

        // The awg rung is the last one this node advertises, so the walk stops
        // there and the heal keeps rebuilding the same conf.
        expect(ctl.transportRung, TransportRung.awg);
        expect(socket.lastConfig, contains('Jc = 3'));
      });

      test('a malformed credential is never selected as a rung', () async {
        // A PSK of the wrong size is exactly what the daemon refuses, so the
        // ladder must not build a transport from it. The entry decodes; it is
        // just not an offer.
        useLinuxDataPlane();
        final (container, socket) = await seedStream(
          dial: () => dialJson(
            awgPort: 51821,
            stream: streamTransportJson(
              psk: base64Encode(List<int>.filled(16, 0xbb)),
            ),
          ),
          controlProbe: support.FakeControlProbe(true),
        );
        final ctl = container.read(connectionProvider.notifier);

        await stepDown(container);
        await stepDown(container);

        expect(ctl.transportRung, TransportRung.awg);
        expect(socket.lastConfig, isNot(contains('Endpoint = 127.0.0.1:')));
      });
    });
  });

  test(
    'confirmed dead echo goes straight to failover after poll failure',
    () async {
      final events = <String>[];
      var fail = false;
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) {
          if (fail) throw networkTimeout(o);
          return activeStatusJson();
        }
        if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
      final ctl = container.read(connectionProvider.notifier);

      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).pollFailures, 0);

      // Same dead peer, but the backend just answered: suppressed entirely.
      staleHandshake(ctl);
      await ctl.checkHealthOnce();

      var state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);

      // A poll failure plus the confirming dead echo is positive path-dead
      // evidence. The failed control probe must not force a same-server heal.
      fail = true;
      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).pollFailures, 1);
      await ctl.checkHealthOnce();
      await ctl.checkHealthOnce();

      state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    },
  );

  test('fresh handshake never heals an idle tunnel', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    // seedConnected leaves a fresh handshake: liveness is proven even with
    // zero traffic, so repeated ticks (and a successful poll) stay put.
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.healthNote, isNull);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

  test('unknown handshake never heals on its own', () async {
    // No native reader (null = unknown): even with failed polls and many
    // ticks the tunnel stays put. Only the degraded-stage path acts here.
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugHandshakeReader = () async => null;
    events.clear();

    await ctl.pollStatusOnce();
    for (var i = 0; i < 5; i++) {
      await ctl.checkHealthOnce();
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
    expect(state.healthNote, isNull);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

  test('never-handshook past the grace heals (supported reader)', () async {
    // The Android/Linux path: a real reader keeps reporting "no handshake
    // yet" (null). Aged past the grace window with a corroborating poll
    // failure, the dead peer heals immediately — no 150s stopwatch, so a
    // powered-off server is detected on the first tick after 30s.
    final events = <String>[];
    final clock = support.FakeClock();
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    }, clock: clock);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugHandshakeReader = () async => null;
    // Age the tunnel-start anchor past the never-handshook grace window
    // (the connect above anchored it at the fake clock's origin).
    clock.advance(ConnectionTuning.firstHandshakeGrace);
    events.clear();

    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
  });

  test(
    'hard-stale handshake fast-tracks a move when the echo is unprobeable',
    () async {
      // Filtered environment: WG UDP blocked (dead handshake) while the
      // control plane stays reachable out-of-band, and wg_dns yields no
      // probeable target so the echo is null every tick. The standard gate is
      // suppressed by the successful poll; the hard ceiling must drive the
      // path-dead fast-track without any performed-dead echo.
      final events = <String>[];
      var handshakeAt = DateTime.now();
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: support.FakeGatewayProbe(null),
        controlProbe: support.FakeControlProbe(true),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugHandshakeReader = () async => handshakeAt;
      // Out-of-band success: pollFailures 0 with a fresh status anchor, so
      // the corroboration gate stays closed.
      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).lastStatusAt, isNotNull);
      events.clear();

      handshakeAt = DateTime.now().subtract(
        ConnectionTuning.hardHandshakeStaleAfter + const Duration(seconds: 1),
      );
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      // Straight to a server move: no offline heal burned, no config fetch.
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('GET:/vpn-regions'));
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    },
  );

  test(
    'a backend-confirmed dead node moves without burning a heal cycle',
    () async {
      // The attributed case the local ladder cannot reach: the handshake is
      // fresh and the in-tunnel echo is alive (one datagram from a node
      // mid-restart), yet the backend has already given up on it. Both local
      // signals say "healthy", so without the node verdict the session would
      // sit there until the next poll. The verdict must skip the heal.
      final events = <String>[];
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/server-status')) {
            return serverStatusJson('offline');
          }
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: support.FakeGatewayProbe(true),
        controlProbe: support.FakeControlProbe(true),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).serverConfirmedDown, isTrue);
      events.clear();

      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      // The whole point: no same-server restart on the way to the move. The
      // one `tunnel:stop` is the move's own teardown (the path is known dead,
      // so discovery and the switch travel direct), not a heal — proven by the
      // heal's signature config fetch being absent.
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    },
  );

  test('a healthy node leaves the local ladder untouched', () async {
    // Same setup as above with an `online` verdict: nothing about the
    // tunnel changed, so the tick must do nothing at all.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/server-status')) {
          return onlineServerStatusJson();
        }
        if (o.path.endsWith('/status')) return activeStatusJson();
        if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(true),
      controlProbe: support.FakeControlProbe(true),
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
    );
    final ctl = container.read(connectionProvider.notifier);
    await ctl.pollStatusOnce();
    events.clear();

    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.serverConfirmedDown, isFalse);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
    expect(state.dial?.serverId, 'srv-1');
    expect(events, isEmpty);
  });

  test(
    'a node-down verdict failovers directly even if the pre-stop probe fails',
    () async {
      // The pre-stop probe can be unreachable through the dead tunnel. The
      // server-down verdict is positive evidence, so discovery must run after
      // teardown and use the direct network.
      final events = <String>[];
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/server-status')) {
            return serverStatusJson('offline');
          }
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: support.FakeGatewayProbe(false),
        controlProbe: support.FakeControlProbe(false),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      await ctl.pollStatusOnce();
      events.clear();

      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(
        events.indexOf('tunnel:stop'),
        lessThan(events.indexOf('GET:/vpn-regions')),
      );
    },
  );

  test(
    'hard-stale handshake failovers directly when the probe is unreachable',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: support.FakeGatewayProbe(null),
        controlProbe: support.FakeControlProbe(false),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      await ctl.pollStatusOnce();
      hardStaleHandshake(ctl);
      events.clear();

      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(events.where((e) => e.startsWith('tunnel:')), [
        'tunnel:stop',
        'tunnel:start',
      ]);
    },
  );

  test(
    'an out-of-band poll does not reset the budget while the handshake is dead',
    () async {
      // A reachable API must not end the outage when the WireGuard path is
      // still dead: otherwise the heal/move ladder resets forever and never
      // escalates.
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      });
      final ctl = container.read(connectionProvider.notifier);
      ctl.snap = ctl.snap.copyWith(
        autoHealAttempts: 2,
        autoFailoverAttempts: 3,
      );
      hardStaleHandshake(ctl);

      await ctl.pollStatusOnce();

      final state = container.read(connectionProvider);
      // The poll itself succeeded...
      expect(state.pollFailures, 0);
      expect(state.lastStatusAt, isNotNull);
      // ...but did not restore the recovery budgets.
      expect(state.autoHealAttempts, 2);
      expect(state.autoFailoverAttempts, 3);
    },
  );

  test(
    'a never-handshook acts at the grace when the control plane answers',
    () async {
      // The blocked-UDP shape: the API answers out-of-band while the tunnel's
      // own path never does, and wg_dns yields no probeable target so the echo
      // is null every tick — there is no performed-dead echo to lean on. The
      // successful poll keeps the corroboration gate closed, so the
      // never-handshook verdict is what carries this, and a reachable control
      // plane makes that enough at [firstHandshakeGrace] instead of at the
      // later uncorroborated ceiling.
      final events = <String>[];
      final clock = support.FakeClock();
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        clock: clock,
        gatewayProbe: support.FakeGatewayProbe(null),
        controlProbe: support.FakeControlProbe(true),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugHandshakeReader = () async => null;
      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).lastStatusAt, isNotNull);
      events.clear();

      // Just below the grace: still gated, so nothing happens.
      clock.advance(
        ConnectionTuning.firstHandshakeGrace - const Duration(seconds: 1),
      );
      await ctl.checkHealthOnce();
      expect(container.read(connectionProvider).autoFailoverAttempts, 0);
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);

      // Past it. This stock region serves no rung below, so there is nothing
      // cheaper than the move and the confirmed dead path takes it.
      clock.advance(const Duration(seconds: 2));
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('GET:/vpn-regions'));
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    },
  );

  test('a never-handshook waits for the hard ceiling when the control plane is down', () async {
    // The same evidence with nobody to corroborate it. A fast-track move stops
    // the tunnel and spends the move budget on local evidence alone, so it
    // waits for [hardFirstHandshakeCeiling]; the cheap same-server restart
    // still happens, because restarting a dead config costs nothing. Without
    // that ceiling the session would sit "Connected" forever with no echo to
    // speak for it.
    final events = <String>[];
    final clock = support.FakeClock();
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      clock: clock,
      gatewayProbe: support.FakeGatewayProbe(null),
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
    );
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugHandshakeReader = () async => null;
    await ctl.pollStatusOnce();
    events.clear();

    // Past the grace but short of the ceiling: the restart runs, no move.
    clock.advance(ConnectionTuning.firstHandshakeGrace);
    await ctl.checkHealthOnce();
    var state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(state.autoFailoverAttempts, 0);
    expect(events.where((e) => e.startsWith('tunnel:')), isNotEmpty);
    // The heal reset the tunnel-start anchor, so the ceiling measures the
    // restarted tunnel — and the incident's heal budget is spent, which is
    // exactly why the ceiling has to be able to move on its own. Re-assert the
    // spent budget the way `_autoHeal` does so this row measures the ceiling
    // rather than the heal budget.
    ctl.snap = ctl.snap.copyWith(autoHealAttempts: 1);
    events.clear();

    // Just below the uncorroborated ceiling: nothing left to act on.
    clock.advance(
      ConnectionTuning.hardFirstHandshakeCeiling - const Duration(seconds: 1),
    );
    await ctl.checkHealthOnce();
    expect(container.read(connectionProvider).autoFailoverAttempts, 0);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);

    // Past it the path is dead on local evidence alone: fast-track the move.
    clock.advance(const Duration(seconds: 2));
    await ctl.checkHealthOnce();

    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoFailoverAttempts, 1);
    expect(state.dial?.serverId, 'srv-2');
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
  });

  test(
    'alive gateway echo suppresses the heal despite a stale handshake',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      });
      final ctl = container.read(connectionProvider.notifier);
      staleHandshake(ctl);
      // In-tunnel echo alive: the data path is healthy even though the peer
      // looks stale and the backend is unreachable.
      (container.read(gatewayProbeProvider) as support.FakeGatewayProbe).alive =
          true;
      events.clear();

      await ctl.pollStatusOnce();
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
    },
  );

  test('a corroborated dead echo goes straight to direct failover', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        if (o.path.endsWith('/server-status')) return onlineServerStatusJson();
        if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(false),
      controlProbe: support.FakeControlProbe(false),
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
    );
    final ctl = container.read(connectionProvider.notifier);
    // Older than the short echo window but far inside the 150s rekey one:
    // the handshake stopwatch alone must not heal yet. Past the probe gate
    // so the echo is actually read. A successful API poll between echoes
    // must not erase the local dead-path evidence.
    ctl.debugHandshakeReader = () async => DateTime.now().subtract(
      ConnectionTuning.echoProbeAfter + const Duration(seconds: 10),
    );
    events.clear();

    // The default harness echo is performed-dead: the early strikes
    // accumulate without shortening anything.
    for (var i = 0; i < ConnectionTuning.echoStallStrikes - 1; i++) {
      await ctl.checkHealthOnce();
    }
    expect(container.read(connectionProvider).autoHealAttempts, 0);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
    await ctl.pollStatusOnce();
    expect(ctl.debugDeadEchoStrikes, 1);

    // The confirming strike proves the local path dead. The API probe is
    // down through the old tunnel, so stop first and use direct discovery.
    await ctl.checkHealthOnce();
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 1);
    expect(state.dial?.serverId, 'srv-2');
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    expect(
      events.indexOf('tunnel:stop'),
      lessThan(events.indexOf('GET:/vpn-regions')),
    );
    // The replacement tunnel starts with a fresh echo-strike run.
    expect(ctl.debugDeadEchoStrikes, 0);
  });

  test(
    'a dead path with the control plane up still moves instead of healing',
    () async {
      // The sibling of the row above, and the branch it cannot reach: there the
      // control plane was down, so the move came from local evidence alone
      // before any probe. Here the API answers, so the decision is made with a
      // live control plane — and it is still a move, because a stock region has
      // no rung below native to step onto and a heal would rebuild the same
      // config on the same rung.
      final events = <String>[];
      final gateway = support.FakeGatewayProbe(false);
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/server-status')) {
            return onlineServerStatusJson();
          }
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: gateway,
        controlProbe: support.FakeControlProbe(true),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      staleHandshake(ctl);

      await ctl.checkHealthOnce();

      // Exactly one performed-dead echo: local evidence alone cannot read as a
      // dead path, so this move could only have been decided after the control
      // plane answered — the branch the pre-probe fast-track cannot reach.
      expect(gateway.calls, 1);
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      // The heal budget is untouched: nothing was rebuilt.
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    },
  );

  test('a fresh handshake skips the echo probe entirely', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    final probe =
        container.read(gatewayProbeProvider) as support.FakeGatewayProbe;
    events.clear();

    // Echo dead every tick, but the peer keeps handshaking: a fresh
    // handshake is positive liveness, so the probe is skipped and a dead
    // datagram run can never accumulate or override it.
    for (var i = 0; i < ConnectionTuning.echoStallStrikes + 3; i++) {
      await ctl.checkHealthOnce();
    }

    expect(probe.calls, 0);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

  test('the echo probe starts once the handshake ages past the gate', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
    final ctl = container.read(connectionProvider.notifier);
    final probe =
        container.read(gatewayProbeProvider) as support.FakeGatewayProbe;
    var handshakeAt = DateTime.now();
    ctl.debugHandshakeReader = () async => handshakeAt;
    events.clear();

    // Still fresh: no probe, no heal.
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    expect(probe.calls, 0);
    expect(container.read(connectionProvider).autoHealAttempts, 0);

    // Cross the gate: a missing rekey is now meaningful, so the echo runs.
    handshakeAt = DateTime.now().subtract(
      ConnectionTuning.echoProbeAfter + const Duration(seconds: 1),
    );
    await ctl.checkHealthOnce();
    expect(probe.calls, 1);
    // One dead echo is not enough: the full stale window still holds.
    expect(container.read(connectionProvider).autoHealAttempts, 0);

    // The confirming dead strike takes the direct failover path.
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    expect(probe.calls, 3);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 1);
    expect(state.dial?.serverId, 'srv-2');
    expect(events.where((e) => e.startsWith('tunnel:')), isNotEmpty);
  });

  test('a successful status poll clears the dead-echo run', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    // Two dead echoes were seen, then the backend answers through the live
    // tunnel: the data path is proven reachable, so the run resets.
    ctl.debugDeadEchoStrikes = ConnectionTuning.echoStallStrikes - 1;

    await ctl.pollStatusOnce();

    expect(ctl.debugDeadEchoStrikes, 0);
  });

  test('a degraded stage event kicks a health tick immediately', () async {
    // The OS reports a stalled stage: without the kick the corroborated
    // stall would wait out the 10s health cadence; here it heals at once.
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    // Stale handshake plus a failed poll corroborate the stall.
    staleHandshake(ctl);
    await ctl.pollStatusOnce();
    events.clear();

    tunnel.emit(VpnStage.noConnection);
    await pumpEventQueue();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
  });

  test('a repeated identical degraded stage does not re-kick', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    final probe =
        container.read(gatewayProbeProvider) as support.FakeGatewayProbe;
    // An alive echo keeps the tick from healing but still consumes the read.
    probe.alive = true;
    staleHandshake(ctl);
    await ctl.pollStatusOnce();

    tunnel.emit(VpnStage.noConnection);
    await pumpEventQueue();
    expect(probe.calls, 1);

    // Same stage again: no transition, so no second kick.
    tunnel.emit(VpnStage.noConnection);
    await pumpEventQueue();
    expect(probe.calls, 1);

    // A different degraded stage is a transition, so it kicks again.
    tunnel.emit(VpnStage.reconnect);
    await pumpEventQueue();
    expect(probe.calls, 2);
  });

  test('health tick publishes traffic counters to state', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    expect(container.read(connectionProvider).rxBytes, isNull);
    expect(container.read(connectionProvider).txBytes, isNull);

    tunnel.traffic = const {'totalDownload': 2048, 'totalUpload': 512};
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.rxBytes, 2048);
    expect(state.txBytes, 512);
  });

  test(
    'external OS stop preserves the server peer, ghost-kills without restart',
    () async {
      final events = <String>[];
      final (container, tunnel) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      });
      final ctl = container.read(connectionProvider.notifier);
      // Corroborated death: stage down, handshake stale, gateway dead.
      staleHandshake(ctl);
      tunnel.stageValue = VpnStage.disconnected;

      await ctl.checkHealthOnce();
      // The ghost kill is fire-and-forget: let it land.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('outside the app'));
      // Server peer preserved for one-tap reconnect: no release call.
      expect(events.where((e) => e.contains('/disconnect')), isEmpty);
      // Plain stop plus a native ghost-kill on the owning backend: the
      // tunnel is never restarted to reclaim a handle.
      expect(events, contains('tunnel:stop'));
      expect(events, isNot(contains('tunnel:start')));
    },
  );

  test('an exiting stage enters outside-stop verification', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    staleHandshake(ctl);
    tunnel.emit(VpnStage.exiting);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('outside the app'));
    expect(events, contains('tunnel:stop'));
  });

  test('unverifiable outside stop adopts and keeps the tunnel up', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    // Fresh handshake (seed default): server truth says alive, local
    // evidence says alive — the replayed lie must not kill anything.
    tunnel.stageValue = VpnStage.disconnected;

    await ctl.checkHealthOnce();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.healthNote, isNull);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
    expect(events.where((e) => e.contains('/disconnect')), isEmpty);
  });

  test('external OS stop grace cleared so a later stop is honored', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    staleHandshake(ctl);
    tunnel.stageValue = VpnStage.disconnected;

    await ctl.checkHealthOnce();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(ctl.debugColdRestoreConfirmedAt, isNull);
    expect(events.where((e) => e.contains('/disconnect')), isEmpty);
  });

  test(
    'external-stop teardown serializes a reconnect queued behind its stop',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final tunnel = BlockingStopTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      ctl.debugHandshakeReader = () async => DateTime.now();
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      events.clear();

      // Corroborated outside stop, with its stop held open so it stays in
      // flight while a reconnect arrives.
      staleHandshake(ctl);
      tunnel.stageValue = VpnStage.disconnected;
      final gate = Completer<void>();
      tunnel.stopGate = gate;
      await ctl.checkHealthOnce();
      for (var i = 0; i < 100 && !tunnel.stopPending; i++) {
        await pumpEventQueue();
      }
      expect(tunnel.stopPending, isTrue, reason: 'teardown stop not reached');
      expect(container.read(connectionProvider).phase, ConnPhase.idle);

      // A Connect tapped while the stop is still in flight must queue behind
      // it (the teardown holds the op mutex), never start a replacement tunnel
      // the lingering stop could then kill.
      final reconnecting = ctl.connect();
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
      }
      expect(
        tunnel.startDuringStop,
        isFalse,
        reason: 'a new tunnel started while the old stop was still pending',
      );

      // Release the stop: the queued Connect now runs against a down tunnel.
      gate.complete();
      await reconnecting;
      await pumpEventQueue();

      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(tunnel.startDuringStop, isFalse);
      expect(events.where((e) => e.startsWith('tunnel:')), [
        'tunnel:stop',
        'tunnel:start',
      ]);
    },
  );

  test(
    'external-stop notFound keeps the device wipe atomic against a reconnect',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys();
      var configCalls = 0;
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            configCalls++;
            // 1: seed connect. 2: the external-stop corroboration, which
            // proves the device is gone. Later calls (the queued reconnect)
            // must succeed so the reconnect can reach a fresh start.
            if (configCalls == 2) throw missingDevice(o);
            return dialJson();
          }
          if (o.path == '/vpn-devices' && o.method == 'POST') {
            return dialJson();
          }
          throw StateError('unexpected ${o.method}:${o.path}');
        }),
      );
      final tunnel = BlockingStopTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      ctl.debugHandshakeReader = () async => DateTime.now();
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      events.clear();

      // notFound teardown: gate the local wipe so it stays in flight.
      staleHandshake(ctl);
      tunnel.stageValue = VpnStage.disconnected;
      final clearGate = Completer<void>();
      var clearPending = false;
      store.clearDeviceHook = () async {
        clearPending = true;
        await clearGate.future;
        clearPending = false;
      };

      await ctl.checkHealthOnce();
      for (var i = 0; i < 100 && !clearPending; i++) {
        await pumpEventQueue();
      }
      expect(clearPending, isTrue, reason: 'clearDevice not reached');

      // A reconnect during the wipe must queue rather than provision a fresh
      // identity that the pending clearDevice would then erase.
      final reconnecting = ctl.connect();
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
      }
      expect(
        events.where((e) => e == 'tunnel:start'),
        isEmpty,
        reason: 'reconnect started a tunnel during the pending device wipe',
      );

      clearGate.complete();
      await reconnecting;
      await pumpEventQueue();

      // The queued reconnect provisioned a fresh identity after the wipe
      // instead of losing one to the stale teardown.
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(await store.deviceId(), 'dev-1');
    },
  );

  test(
    'external-stop peerless drops the cached dial but keeps the device',
    () async {
      final events = <String>[];
      final store = FakeStore();
      final keys = FakeKeys();
      var configCalls = 0;
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) {
            configCalls++;
            // 1: seed connect. 2: the external-stop corroboration, which finds
            // the device alive but peerless.
            if (configCalls == 2) throw peerless(o);
            return dialJson();
          }
          throw StateError('unexpected ${o.method}:${o.path}');
        }),
      );
      final tunnel = FakeTunnel(events);
      final container = makeContainer(store: store, keys: keys, api: api);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;
      ctl.debugHandshakeReader = () async => DateTime.now();
      await ctl.connect();
      expect(container.read(connectionProvider).phase, ConnPhase.connected);
      expect(await store.lastDialJson(), isNotNull);
      events.clear();

      staleHandshake(ctl);
      tunnel.stageValue = VpnStage.disconnected;
      await ctl.checkHealthOnce();
      await pumpEventQueue();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.idle);
      expect(state.message, contains('Session expired'));
      // Device kept for a fresh bind, but the peer is gone so the cold-start
      // dial must not survive.
      expect(await store.deviceId(), 'dev-1');
      expect(await store.lastDialJson(), isNull);
    },
  );

  /// One corroborated stall cycle: stale handshake plus 2 failed polls
  /// (backend unreachable), then a single health tick. Handshake staleness
  /// needs no multi-tick baselining: one tick drives one escalation rung.
  Future<void> stallOnce(ConnectionController ctl) async {
    staleHandshake(ctl);
    await ctl.pollStatusOnce();
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();
  }

  test('persistent stall escalates to a different server', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Chain: heal, then a straight escalation to failover.
    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    // Unpinned (Auto) failover roams without pinning: the next connect
    // re-picks instead of sticking to the failover target.
    expect(state.serverId, isNull);
    expect(state.autoFailoverAttempts, 1);
    expect(state.autoHealAttempts, 0);
    expect(state.recoveryAction, RecoveryAction.switchingServer);
    expect(state.recoveryReason, RecoveryReason.staleHandshake);
    expect(events, contains('GET:/vpn-regions'));
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    // The failover stopped the old tunnel before discovery (direct
    // network) and started the new one after.
    expect(events.where((e) => e == 'tunnel:stop'), isNotEmpty);
    expect(events.where((e) => e == 'tunnel:start'), isNotEmpty);
    // The null echo is unknown rather than positive path-dead evidence, so
    // failover discovery probes the still-running tunnel before stopping it.
    final regionsAt = events.indexOf('GET:/vpn-regions');
    expect(regionsAt, greaterThan(0));
    expect(events[regionsAt - 1], startsWith('GET:'));
  });

  test('an unreachable control probe waits after the local heal', () async {
    // Gateway unprobeable (null echo) and the control probe is a performed
    // failure: after one local heal, recovery must wait rather than stop the
    // tunnel and spend a failover budget that cannot make an API call.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(false),
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
    );
    final ctl = container.read(connectionProvider.notifier);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.autoHealAttempts, 1);
    expect(state.autoFailoverAttempts, 0);
    expect(state.recoveryAction, RecoveryAction.waiting);
    expect(state.recoveryReason, RecoveryReason.controlPlaneUnavailable);
    expect(state.healthNote, contains('Waiting for the control plane'));
    expect(events, isNot(contains('GET:/vpn-regions')));
  });

  test('failover with no other capacity stays on the old server', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers().sublist(0, 1));
        }
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Same chain; the no-capacity branch restarts the old tunnel
    // instead of moving, and says why it stays put.
    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.autoFailoverAttempts, 1);
    expect(state.recoveryAction, RecoveryAction.restarting);
    expect(state.recoveryReason, RecoveryReason.noAlternativeServer);
    expect(state.healthNote, contains('No other server'));
    expect(events, contains('GET:/vpn-regions'));
    expect(events, isNot(contains('POST:/vpn-devices/dev-1/switch')));
    // Fallback restart kept a tunnel running.
    expect(events, contains('tunnel:start'));
  });

  /// A third stock-only node, for the roaming suites. Its ladder is `native`
  /// alone, so a move onto it always lands on the floor.
  Map<String, dynamic> dialJsonSrv9() => dialJson(
    serverId: 'srv-9',
    serverName: 'nine',
    assignedIp: '10.8.0.9',
    endpoint: '203.0.113.19',
    wgPublicKey: 'SRV9',
  );

  Map<String, dynamic> serverJson(String id, String name, int peers) => {
    'id': id,
    'name': name,
    'endpoint': '203.0.113.10',
    'wg_port': 51820,
    'wg_dns': '10.8.0.1',
    'wg_public_key': 'SRV',
    'active_peers': peers,
  };

  List<Map<String, dynamic>> twoRegionsSingleEach() => [
    {
      'id': 'r1',
      'name': 'R1',
      'country_code': null,
      'servers': [serverJson('srv-1', 'one', 9)],
    },
    {
      'id': 'r2',
      'name': 'R2',
      'country_code': null,
      'servers': [serverJson('srv-9', 'nine', 1)],
    },
  ];

  test('unpinned failover roams across regions', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) return twoRegionsSingleEach();
        if (o.path.endsWith('/switch')) return dialJsonSrv9();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    // Unpinned (Auto) after the fresh connect: failover may roam globally
    // and stays unpinned.
    expect(container.read(connectionProvider).explicitTarget, isFalse);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-9');
    expect(state.autoFailoverAttempts, 1);
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
  });

  test('pinned server with a dead region roams and drops the pin', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) return twoRegionsSingleEach();
        if (o.path.endsWith('/switch')) return dialJsonSrv9();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    // Explicit server tap: r1 holds only the dead srv-1, r2 has capacity.
    // The pin is a preference, not a boundary — the move roams rather than
    // stranding the session on a dead server.
    ctl.selectTarget(serverId: 'srv-1', explicitTarget: true);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-9');
    expect(state.autoFailoverAttempts, 1);
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    // The pin is void once its region is gone, so it drops to Auto instead
    // of persisting a server in a region the user never chose.
    expect(state.serverId, isNull);
    expect(state.explicitTarget, isFalse);
    expect(state.healthNote, contains('R2'));
    expect(state.healthNote, contains('Back on Auto'));
  });

  test('a pinned server missing from discovery still roams', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        // srv-1 is gone from discovery entirely: the parent region cannot
        // be resolved, which used to mean the pinned no-capacity error.
        if (o.path.endsWith('/vpn-regions')) {
          return [
            {
              'id': 'r2',
              'name': 'R2',
              'country_code': null,
              'servers': [serverJson('srv-9', 'nine', 1)],
            },
          ];
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv9();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    ctl.selectTarget(serverId: 'srv-1', explicitTarget: true);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-9');
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    // A pin whose server vanished is void whatever the replacement is.
    expect(state.serverId, isNull);
    expect(state.explicitTarget, isFalse);
  });

  test('a pinned server keeps its pin when the whole fleet is empty', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers().sublist(0, 1));
        }
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    ctl.selectTarget(serverId: 'srv-1', explicitTarget: true);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    // No capacity anywhere, so there is nothing to roam to: the converged
    // no-capacity path bounces the old tunnel and keeps the pin intact.
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.serverId, 'srv-1');
    expect(state.explicitTarget, isTrue);
    expect(state.autoFailoverAttempts, 1);
    expect(state.healthNote, contains('No other server'));
    expect(events, isNot(contains('POST:/vpn-devices/dev-1/switch')));
  });

  test('pinned server allows same-region moves', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    // Explicit server tap: srv-2 in the same region stays a valid target.
    ctl.selectTarget(serverId: 'srv-1', explicitTarget: true);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, 'srv-2');
    expect(state.explicitTarget, isTrue);
    expect(state.autoFailoverAttempts, 1);
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
  });

  test('auto-failover surfaces a keypair persistence failure', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('SWITCH-PRIV', 'SWITCH-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);
    final store = container.read(deviceStoreProvider) as FakeStore;
    store.setKeypairHook = (_, _) async {
      throw StateError('secure storage unavailable');
    };

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(state.message, contains('Could not save the recovered key'));
    expect(await store.privateKey(), 'OLD-PRIV');
  });

  test(
    'auto-failover rebinds when the switch finds a peerless device',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) throw networkTimeout(o);
          if (o.path.endsWith('/vpn-regions')) {
            return regionsList(twoServers());
          }
          if (o.path.endsWith('/switch')) throw peerless(o);
          if (o.path.endsWith('/connect')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        keyQueue: const [
          Keypair('SWITCH-PRIV', 'SWITCH-PUB'),
          Keypair('FRESH-PRIV', 'FRESH-PUB'),
        ],
        gatewayProbe: support.FakeGatewayProbe(null),
        controlProbe: support.FakeControlProbe(true),
      );
      final ctl = container.read(connectionProvider.notifier);

      for (var i = 0; i < 2; i++) {
        await stallOnce(ctl);
      }

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      expect(state.autoFailoverAttempts, 1);
      expect(events, contains('POST:/vpn-devices/dev-1/connect'));
      expect(
        await container.read(deviceStoreProvider).privateKey(),
        'FRESH-PRIV',
      );
    },
  );

  test('failover transport failure restarts the old tunnel', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) throw networkTimeout(o);
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Heal, then a failover whose switch POST fails: the old tunnel is
    // restarted instead. Two cycles suffice since a single failed poll now
    // corroborates (a third cycle would spend failover attempt #2 against
    // the same dead switch).
    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.autoFailoverAttempts, 1);
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
  });

  test('quiet backend escalates heal -> failover with no polls', () async {
    // Regression test for the >2min auto-heal loop: no status poll ever
    // runs (outage starts between the 60s polls), so the old
    // `pollFailures >= 1` gate never opened and the same dead config
    // restarted forever. Escalation must proceed on local evidence, and
    // the next stall must move servers instead of restarting the same
    // config for another detection cycle.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Stale handshake, no poll ever ran: the quiet slow-track
    // corroborates on local evidence alone -> heal#1.
    staleHandshake(ctl);
    await ctl.checkHealthOnce();
    var state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);

    // The next stale tick escalates straight to failover on the new
    // server — no same-server config refresh in between.
    await ctl.checkHealthOnce();
    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, isNull);
    expect(state.autoFailoverAttempts, 1);
    expect(state.autoHealAttempts, 0);
    expect(events, contains('GET:/vpn-regions'));
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    // No config fetch and no status poll: escalation was purely local.
    expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    expect(events.where((e) => e.contains('/status')), isEmpty);
  });

  test('persistent 5xx status errors surface a degraded banner', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: o,
            statusCode: 500,
            data: const {'detail': 'Internal Server Error'},
          ),
          error: const ApiException(
            ApiErrorKind.unknown,
            'Internal Server Error',
            500,
          ),
        );
      }
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    await ctl.pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    // A reachable backend never counts toward escalation...
    expect(state.pollFailures, 0);
    // ...but the user must not see a perpetual "Connected" while every poll
    // fails: a degraded banner appears until a poll succeeds again.
    expect(state.healthNote, contains('Backend error (500)'));
  });

  test('answered 5xx suppresses a standard stale-handshake heal', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: o,
            statusCode: 500,
            data: const {'detail': 'Internal Server Error'},
          ),
          error: const ApiException(
            ApiErrorKind.unknown,
            'Internal Server Error',
            500,
          ),
        );
      }
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    staleHandshake(ctl);
    events.clear();

    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.backendIssue, BackendIssue.serverError);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

  test(
    'fresh poll successes do not suppress confirmed local path failover',
    () async {
      // A successful status poll cannot overrule two performed-dead gateway
      // echoes. The failed pre-stop probe must not block direct failover.
      final events = <String>[];
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        controlProbe: support.FakeControlProbe(false),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      events.clear();

      staleHandshake(ctl);

      // Every poll proves the backend reachable, but it cannot vouch for the
      // WireGuard path when the gateway echo is dead.
      await ctl.pollStatusOnce(); // backend proven reachable
      await ctl.checkHealthOnce();
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
      expect(events, contains('GET:/vpn-regions'));
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    },
  );

  test('status poll racing a heal stop is skipped, not counted', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    final store = container.read(deviceStoreProvider) as FakeStore;
    events.clear();

    // A heal takes the mutex and stops the tunnel during the poll's
    // device-id read: the re-check must skip the API call instead of
    // firing into the teardown (errno-10057 connectionError).
    store.deviceIdHook = () async {
      ctl.snap = ctl.snap.copyWith(phase: ConnPhase.working);
    };
    await ctl.pollStatusOnce();
    store.deviceIdHook = null;

    expect(events.where((e) => e.contains('/status')), isEmpty);
    expect(container.read(connectionProvider).pollFailures, 0);
    ctl.snap = ctl.snap.copyWith(phase: ConnPhase.connected);
  });

  test('in-flight status poll killed by a heal is not counted', () async {
    // The poll is already inside GET …/status when the heal stops the
    // tunnel: its transport failure must not inflate pollFailures.
    final events = <String>[];
    final gate = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          events.add('${options.method}:${options.path}');
          if (options.path.endsWith('/status')) {
            await gate.future;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: const ApiException(
                  ApiErrorKind.network,
                  'No network connection.',
                ),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: dialJson(),
            ),
          );
        },
      ),
    );
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final container = makeContainer(store: store, keys: keys, api: VpnApi(dio));
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    await ctl.connect();
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    events.clear();

    final poll = ctl.pollStatusOnce();
    // Let the poll get past its entry checks into the gated GET.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ctl.snap = ctl.snap.copyWith(
      phase: ConnPhase.working,
      message: 'Reconnecting…',
    );
    gate.complete();
    await poll;

    expect(events, contains('GET:/vpn-devices/dev-1/status'));
    expect(container.read(connectionProvider).pollFailures, 0);
    ctl.snap = ctl.snap.copyWith(phase: ConnPhase.connected);
  });

  test('a delayed status 404 cannot forget a restarted session', () async {
    final events = <String>[];
    final statusStarted = Completer<void>();
    final releaseStatus = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          events.add('${options.method}:${options.path}');
          if (options.path.endsWith('/config')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: dialJson(),
              ),
            );
            return;
          }
          if (options.path.endsWith('/status')) {
            if (!statusStarted.isCompleted) statusStarted.complete();
            await releaseStatus.future;
            handler.reject(missingDevice(options));
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              error: StateError('unexpected ${options.path}'),
            ),
          );
        },
      ),
    );
    final store = FakeStore();
    final container = makeContainer(
      store: store,
      keys: FakeKeys(const []),
      api: VpnApi(dio),
    );
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    await ctl.connect();
    staleHandshake(ctl);
    events.clear();

    final poll = ctl.pollStatusOnce();
    await statusStarted.future;
    await ctl.checkHealthOnce();
    releaseStatus.complete();
    await poll;

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(await store.deviceId(), 'dev-1');
    expect(state.autoHealAttempts, greaterThanOrEqualTo(1));
  });

  test('auto-heal preserves poll failures across the restart', () async {
    // Regression for the 3-minute failover: `_startWith` used to reset
    // pollFailures, wiping the outage evidence so the next escalation
    // needed two fresh 60s polls from scratch.
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    await ctl.pollStatusOnce();
    expect(container.read(connectionProvider).pollFailures, 1);

    staleHandshake(ctl);
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(state.pollFailures, 1);
  });

  test('one failed poll corroborates the next stall into failover', () async {
    // Powered-off server, idle user after the first heal: a single failed
    // poll must be enough to escalate — previously two full 60s poll
    // intervals were needed before the escalation even started.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          return regionsList(twoServers());
        }
        if (o.path.endsWith('/switch')) return dialJsonSrv2();
        throw StateError('unexpected ${o.path}');
      },
      keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Cycle 1: stale handshake heals offline with zero polls (quiet
    // slow-track: never polled counts as unreachable).
    staleHandshake(ctl);
    await ctl.checkHealthOnce();
    var state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(state.pollFailures, 0);

    // Cycle 2: one failed poll, then the stale handshake. The stall now
    // escalates straight to failover on the new server.
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-2');
    expect(state.serverId, isNull);
    expect(state.autoFailoverAttempts, 1);
    expect(state.autoHealAttempts, 0);
    expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    expect(events, contains('GET:/vpn-regions'));
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
  });

  test('poll failing after a heal restart is not counted (epoch)', () async {
    // The errno-10057 case from the field log: the poll's socket dies with
    // the heal's tunnel stop, but the failure lands after the heal already
    // flipped back to `connected` — so the phase guard alone can't catch
    // it. The tunnel epoch must suppress it instead.
    final events = <String>[];
    final gate = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          events.add('${options.method}:${options.path}');
          if (options.path.endsWith('/status')) {
            await gate.future;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: const ApiException(
                  ApiErrorKind.network,
                  'No network connection.',
                ),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: dialJson(),
            ),
          );
        },
      ),
    );
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final container = makeContainer(store: store, keys: keys, api: VpnApi(dio));
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    staleHandshake(ctl);
    await ctl.connect();
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    events.clear();

    // One corroborating failure on the books before the race.
    ctl.snap = ctl.snap.copyWith(pollFailures: 1);

    final poll = ctl.pollStatusOnce();
    // Let the poll get past its entry checks into the gated GET.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // Heal restarts the tunnel while the poll is in flight (bumps the
    // epoch) and lands back on `connected` before the poll fails.
    await ctl.checkHealthOnce();
    expect(container.read(connectionProvider).autoHealAttempts, 1);
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    gate.complete();
    await poll;

    expect(events, contains('GET:/vpn-devices/dev-1/status'));
    expect(container.read(connectionProvider).pollFailures, 1);
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
  });

  test('stale poll success after a restart keeps outage evidence', () async {
    // Mirror image: a poll started before the restart must not clear the
    // outage (pollFailures/lastStatusAt) when it succeeds afterwards.
    final events = <String>[];
    final gate = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          events.add('${options.method}:${options.path}');
          if (options.path.endsWith('/status')) {
            await gate.future;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: activeStatusJson(),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: dialJson(),
            ),
          );
        },
      ),
    );
    final store = FakeStore();
    final keys = FakeKeys(const []);
    final container = makeContainer(store: store, keys: keys, api: VpnApi(dio));
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    staleHandshake(ctl);
    await ctl.connect();
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    events.clear();

    ctl.snap = ctl.snap.copyWith(pollFailures: 1);
    expect(container.read(connectionProvider).lastStatusAt, isNull);

    final poll = ctl.pollStatusOnce();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await ctl.checkHealthOnce();
    expect(container.read(connectionProvider).autoHealAttempts, 1);
    gate.complete();
    await poll;

    final state = container.read(connectionProvider);
    expect(state.pollFailures, 1);
    expect(state.lastStatusAt, isNull);
  });

  test('wedged handshake reads never heal on their own', () async {
    // Wedged driver: every handshake read times out (null = unknown). With
    // no handshake there is no dead-peer evidence, so the tunnel stays put.
    // (Traffic is wedged too; it is display-only and never decides.)
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    tunnel.wedgeTraffic = true;
    ctl.debugHandshakeReader = () =>
        throw TimeoutException('wedged', const Duration(seconds: 3));
    events.clear();

    await ctl.pollStatusOnce();
    for (var i = 0; i < 5; i++) {
      await ctl.checkHealthOnce();
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
    expect(state.healthNote, isNull);
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

  test('background health tick skips the display-only traffic read', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    // Foreground: the tick reads traffic and publishes the counters.
    await ctl.checkHealthOnce();
    expect(tunnel.trafficReads, 1);
    expect(container.read(connectionProvider).rxBytes, 1000);

    ctl.setBackgrounded(true);
    await ctl.checkHealthOnce();
    expect(tunnel.trafficReads, 1);
    // The null (skipped) read never publishes, so the last counters survive.
    expect(container.read(connectionProvider).rxBytes, 1000);

    ctl.setBackgrounded(false);
    await ctl.checkHealthOnce();
    expect(tunnel.trafficReads, 2);
  });

  test(
    'a successful move drops the dead-node verdict for the new server',
    () async {
      // `serverConfirmedDown` is a verdict about one serving node, but it
      // lives on the session. The health tick reads it as attributed cause
      // (it outranks a live gateway echo), so a verdict left set after the
      // move fast-tracks *another* move off a healthy server on the next
      // tick — draining the whole move budget and ending in an error with
      // the tunnel never having been broken.
      //
      // Background is the shape that exposes it: the early status poll is
      // skipped there, so nothing rewrites the flag before the next health
      // tick (15s) and the next status poll (60s) both do.
      final events = <String>[];
      var nodeOffline = true;
      final (container, _) = await seedConnected(
        events,
        (o) {
          if (o.path.endsWith('/config')) return dialJson();
          if (o.path.endsWith('/server-status')) {
            return serverStatusJson(nodeOffline ? 'offline' : 'online');
          }
          if (o.path.endsWith('/status')) return activeStatusJson();
          if (o.path.endsWith('/vpn-regions')) return regionsList(twoServers());
          if (o.path.endsWith('/switch')) return dialJsonSrv2();
          throw StateError('unexpected ${o.path}');
        },
        gatewayProbe: support.FakeGatewayProbe(true),
        controlProbe: support.FakeControlProbe(true),
        keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')],
      );
      final ctl = container.read(connectionProvider.notifier);
      ctl.setBackgrounded(true);
      await ctl.pollStatusOnce();
      expect(container.read(connectionProvider).serverConfirmedDown, isTrue);
      events.clear();

      // The node is back; the move is what has to retire the verdict.
      nodeOffline = false;
      await ctl.checkHealthOnce();
      var state = container.read(connectionProvider);
      expect(state.dial?.serverId, 'srv-2');
      expect(state.autoFailoverAttempts, 1);
      expect(
        state.serverConfirmedDown,
        isFalse,
        reason: 'the verdict described srv-1, and the session is on srv-2',
      );

      // A further tick must be a no-op: srv-2 is healthy, and no status
      // poll has run to correct the flag.
      events.clear();
      await ctl.checkHealthOnce();
      state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.dial?.serverId, 'srv-2');
      expect(state.autoFailoverAttempts, 1);
      expect(events, isNot(contains('GET:/vpn-regions')));
      expect(events, isNot(contains('POST:/vpn-devices/dev-1/switch')));
    },
  );

  test('a failed direct failover fallback keeps the dead-node verdict', () async {
    // If direct discovery itself fails, the old tunnel is restarted, but the
    // backend's node-down verdict must survive so the next health tick retries
    // failover rather than treating the server as healthy.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/server-status')) {
          return serverStatusJson('offline');
        }
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(false),
    );
    final ctl = container.read(connectionProvider.notifier);
    await ctl.pollStatusOnce();
    expect(container.read(connectionProvider).serverConfirmedDown, isTrue);

    // The hard-stale path skips the failed in-tunnel probe and attempts direct
    // discovery. This fake has no regions response, so it falls back to the
    // old dial while retaining the down verdict and charging the move attempt.
    hardStaleHandshake(ctl);
    await ctl.checkHealthOnce();
    final state = container.read(connectionProvider);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 1);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.serverConfirmedDown, isTrue);
    expect(events, contains('GET:/vpn-regions'));
  });

  test('a failing regions discovery does not spend the move budget', () async {
    // The control probe answers `/health` while `/vpn-regions` fails at the
    // app level (500/429). Nothing moved and the tunnel is never stopped, so
    // charging a move would walk the session into
    // `_surfaceRecoveryExhausted` in a few ticks — dropping a healthy tunnel
    // over a discovery endpoint that was only ever erroring.
    final events = <String>[];
    final (container, tunnel) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw networkTimeout(o);
        if (o.path.endsWith('/vpn-regions')) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: o,
              statusCode: 500,
              data: const {'detail': 'boom'},
            ),
          );
        }
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(true),
    );
    final ctl = container.read(connectionProvider.notifier);

    // Heal, then several ticks that each attempt (and fail) a move.
    for (var i = 0; i < 5; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.dial?.serverId, 'srv-1');
    expect(state.autoFailoverAttempts, 0);
    expect(
      state.autoHealAttempts,
      1,
      reason: 'one heal, then the move path retries without spending budget',
    );
    // The tunnel was only cycled by the heal, never by a failed move.
    expect(events.where((e) => e == 'tunnel:stop'), hasLength(1));
    expect(tunnel.stageValue, isNot(VpnStage.disconnected));
  });
}
