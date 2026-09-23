import 'dart:async';

import 'package:boltmesh/core/clock.dart';
import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
import 'package:boltmesh/features/vpn/state/connection_tuning.dart';
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
    : super(events: events, traffic: const {'rx': 1000});
}

ProviderContainer makeContainer({
  required FakeStore store,
  required FakeKeys keys,
  required VpnApi api,
  Clock? clock,
  GatewayProbe? gatewayProbe,
  ControlPlaneProbe? controlProbe,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(keys),
      vpnApiProvider.overrideWithValue(api),
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
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
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

  Map<String, dynamic> dialJsonSrv2() => {
    'id': 'dev-1',
    'assigned_ip': '10.8.0.6',
    'server_id': 'srv-2',
    'server_name': 'two',
    'endpoint': '203.0.113.11',
    'wg_port': 51820,
    'wg_dns': '10.8.0.1',
    'wg_public_key': 'SRV2',
  };

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

  test('spent failover budget keeps healing on the cached config', () async {
    // Failover budget already spent: escalation stays local and keeps
    // restarting same-server (nowhere to move to).
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

    // Cycle 2: the failover budget is spent, so the next stall keeps
    // healing same-server. No regions discovery may run (escalation is
    // budget-gated).
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();

    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 2);
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
      });
      final ctl = container.read(connectionProvider.notifier);
      ctl.snap = ctl.snap.copyWith(autoFailoverAttempts: 3);
      staleHandshake(ctl);

      // Two trailing heals are allowed after the move budget is spent.
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

  test('stale handshake never heals with a healthy backend', () async {
    final events = <String>[];
    var fail = false;
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        if (fail) throw networkTimeout(o);
        return activeStatusJson();
      }
      throw StateError('unexpected ${o.path}');
    });
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

    // Same signature after a poll failure is corroborated: heals offline.
    fail = true;
    await ctl.pollStatusOnce();
    expect(container.read(connectionProvider).pollFailures, 1);
    await ctl.checkHealthOnce();

    state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
    expect(events.where((e) => e.startsWith('tunnel:')), [
      'tunnel:stop',
      'tunnel:start',
    ]);
  });

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
    // powered-off server is detected on the first tick after 45s.
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

  test('hard-stale handshake heals despite a poll that proved the backend reachable', () async {
    // The same out-of-band suppression, but the control-plane probe is also
    // unreachable: totalBlackout would normally keep the tunnel up (the
    // "backend reachable" guard). The hard stall must bypass that guard and
    // take the cheap same-server restart.
    final events = <String>[];
    final (container, _) = await seedConnected(
      events,
      (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) return activeStatusJson();
        throw StateError('unexpected ${o.path}');
      },
      gatewayProbe: support.FakeGatewayProbe(null),
      controlProbe: support.FakeControlProbe(false),
    );
    final ctl = container.read(connectionProvider.notifier);
    await ctl.pollStatusOnce();
    hardStaleHandshake(ctl);
    events.clear();

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
    'a restarted tunnel that never handshakes escalates at the hard ceiling',
    () async {
      // Post-restart the observed-handshake ceiling has no timestamp to age,
      // so the never-handshook branch must carry the ladder forward once the
      // hard grace passes — otherwise a dead peer sits "Connected" forever
      // while out-of-band polls keep succeeding.
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
      events.clear();

      // Just below the hard grace: still gated (the recent poll keeps
      // corroboration away), so nothing happens.
      clock.advance(
        ConnectionTuning.hardFirstHandshakeCeiling - const Duration(seconds: 1),
      );
      await ctl.pollStatusOnce();
      await ctl.checkHealthOnce();
      expect(container.read(connectionProvider).autoFailoverAttempts, 0);
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);

      // Past the hard grace the tunnel path is dead: fast-track a move.
      clock.advance(const Duration(seconds: 2));
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    },
  );

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

  test(
    'a corroborated dead echo shortens the stale window to a few ticks',
    () async {
      final events = <String>[];
      final (container, _) = await seedConnected(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      });
      final ctl = container.read(connectionProvider.notifier);
      // Older than the short echo window but far inside the 150s rekey one:
      // the handshake stopwatch alone must not heal yet. Past the probe
      // gate so the echo is actually read.
      ctl.debugHandshakeReader = () async => DateTime.now().subtract(
        ConnectionTuning.echoProbeAfter + const Duration(seconds: 1),
      );
      events.clear();

      // The default harness echo is performed-dead: the early strikes
      // accumulate without shortening anything.
      for (var i = 0; i < ConnectionTuning.echoStallStrikes - 1; i++) {
        await ctl.checkHealthOnce();
      }
      expect(container.read(connectionProvider).autoHealAttempts, 0);
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);

      // The confirming strike collapses the window and heals the dead peer.
      await ctl.checkHealthOnce();
      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 1);
      expect(events.where((e) => e.startsWith('tunnel:')), [
        'tunnel:stop',
        'tunnel:start',
      ]);
      // The restart re-earns its strikes for the new tunnel generation.
      expect(ctl.debugDeadEchoStrikes, 0);
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
      throw StateError('unexpected ${o.path}');
    });
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

    // The confirming strike run collapses the window and heals the dead peer.
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    expect(probe.calls, 3);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 1);
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
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
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
    expect(state.regionId, isNull);
    expect(state.serverId, isNull);
    expect(state.autoFailoverAttempts, 1);
    expect(state.autoHealAttempts, 0);
    expect(events, contains('GET:/vpn-regions'));
    expect(events, contains('POST:/vpn-devices/dev-1/switch'));
    // The failover stopped the old tunnel before discovery (direct
    // network) and started the new one after.
    expect(events.where((e) => e == 'tunnel:stop'), isNotEmpty);
    expect(events.where((e) => e == 'tunnel:start'), isNotEmpty);
    // Post-heal escalation is path-dead: never probe the tunnel that just
    // failed a restart. The stop lands immediately before discovery.
    final regionsAt = events.indexOf('GET:/vpn-regions');
    expect(regionsAt, greaterThan(0));
    expect(events[regionsAt - 1], 'tunnel:stop');
  });

  test(
    'an unreachable control probe makes the post-heal move path-dead',
    () async {
      // Gateway unprobeable (null echo) but the control probe is a performed
      // failure: the escalation after one heal must still stop before
      // discovery instead of probing a path already proven bad.
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
      expect(state.dial?.serverId, 'srv-2');
      expect(state.autoFailoverAttempts, 1);
      final regionsAt = events.indexOf('GET:/vpn-regions');
      expect(regionsAt, greaterThan(0));
      expect(events[regionsAt - 1], 'tunnel:stop');
    },
  );

  test('failover with no other capacity stays on the old server', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers().sublist(0, 1));
      }
      throw StateError('unexpected ${o.path}');
    });
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
    expect(state.healthNote, contains('No other server'));
    expect(events, contains('GET:/vpn-regions'));
    expect(events, isNot(contains('POST:/vpn-devices/dev-1/switch')));
    // Fallback restart kept a tunnel running.
    expect(events, contains('tunnel:start'));
  });

  Map<String, dynamic> dialJsonSrv9() => {
    'id': 'dev-1',
    'assigned_ip': '10.8.0.9',
    'server_id': 'srv-9',
    'server_name': 'nine',
    'endpoint': '203.0.113.19',
    'wg_port': 51820,
    'wg_dns': '10.8.0.1',
    'wg_public_key': 'SRV9',
  };

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
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) return twoRegionsSingleEach();
      if (o.path.endsWith('/switch')) return dialJsonSrv9();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
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

  test('pinned region never switches regions, surfaces error', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) return twoRegionsSingleEach();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    // Explicit region tap: r1 holds only the dead srv-1, r2 has capacity
    // that must NOT be used.
    ctl.selectTarget(regionId: 'r1', serverId: null, explicitTarget: true);

    for (var i = 0; i < 2; i++) {
      await stallOnce(ctl);
    }

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.error);
    expect(state.message, contains('selected region'));
    expect(state.dial?.serverId, 'srv-1');
    expect(state.lastStage, isNull);
    expect(state.autoFailoverAttempts, 1);
    expect(events, contains('GET:/vpn-regions'));
    expect(events, isNot(contains('POST:/vpn-devices/dev-1/switch')));
    // The tunnel was stopped for discovery and never restarted: the last
    // tunnel event is the stop (cycle 1's heal restarts, then the
    // failover stops for good).
    final tunnelEvents = events.where((e) => e.startsWith('tunnel:')).toList();
    expect(tunnelEvents, isNotEmpty);
    expect(tunnelEvents.last, 'tunnel:stop');
  });

  test('pinned server allows same-region moves', () async {
    final events = <String>[];
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
    final ctl = container.read(connectionProvider.notifier);
    // Explicit server tap: srv-2 in the same region stays a valid target.
    ctl.selectTarget(regionId: null, serverId: 'srv-1', explicitTarget: true);

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
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('SWITCH-PRIV', 'SWITCH-PUB')]);
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
    final (container, tunnel) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) throw networkTimeout(o);
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
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
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
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
    expect(state.regionId, isNull);
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

  test('fresh poll successes suppress heals entirely', () async {
    // Same dead peer, but the backend keeps answering: the quiet slow-track
    // stays shut and — since a stale handshake needs backend corroboration —
    // no heal fires at all.
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) return activeStatusJson();
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);
    events.clear();

    staleHandshake(ctl);

    // Every poll proves the backend reachable, so corroboration never
    // opens — repeated stale ticks stay put.
    await ctl.pollStatusOnce(); // backend proven reachable
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();
    await ctl.pollStatusOnce();
    await ctl.checkHealthOnce();
    await ctl.checkHealthOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.autoHealAttempts, 0);
    expect(state.autoFailoverAttempts, 0);
    expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    expect(events, isNot(contains('GET:/vpn-regions')));
    expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
  });

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
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw networkTimeout(o);
      if (o.path.endsWith('/vpn-regions')) {
        return regionsList(twoServers());
      }
      if (o.path.endsWith('/switch')) return dialJsonSrv2();
      throw StateError('unexpected ${o.path}');
    }, keyQueue: const [Keypair('NEW-PRIV', 'NEW-PUB')]);
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
    expect(state.regionId, isNull);
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
}
