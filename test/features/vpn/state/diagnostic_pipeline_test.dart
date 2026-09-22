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
  FakeTunnel(List<String> events)
    : super(events: events, traffic: const {'rx': 1000});
}

Future<(ProviderContainer, FakeTunnel, ConnectionController)> seedPipeline(
  List<String> events,
  dynamic Function(RequestOptions options) respond, {
  bool link = true,
  bool gatewayAlive = false,
  bool? apiReachable = false,
}) async {
  final store = FakeStore();
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(FakeKeys()),
      vpnApiProvider.overrideWithValue(VpnApi(recordingDio(events, respond))),
      networkMonitorProvider.overrideWithValue(
        support.FakeNetworkMonitor(link),
      ),
      gatewayProbeProvider.overrideWithValue(
        support.FakeGatewayProbe(gatewayAlive),
      ),
      controlPlaneProbeProvider.overrideWithValue(
        support.FakeControlProbe(apiReachable),
      ),
    ],
  );
  addTearDown(container.dispose);
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final tunnel = FakeTunnel(events);
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  ctl.debugHandshakeReader = () async => DateTime.now();
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
  events.clear();
  return (container, tunnel, ctl);
}

void staleHandshake(ConnectionController ctl) {
  ctl.debugHandshakeReader = () async =>
      DateTime.now().subtract(const Duration(minutes: 5));
}

void main() {
  group('diagnostic pipeline', () {
    test('no link pauses heals without burning budgets', () async {
      final events = <String>[];
      final (container, _, ctl) = await seedPipeline(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }, link: false);
      staleHandshake(ctl);
      // Never polled: the quiet slow-track corroborates the stall, but the
      // dead link must freeze escalation before any probe or restart runs.
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 0);
      expect(state.healthNote, contains('Waiting for network'));
      expect(events.where((e) => e.startsWith('tunnel:')), isEmpty);
      expect(events.where((e) => e.startsWith('GET:')), isEmpty);
    });

    test('alive gateway suppresses the heal', () async {
      final events = <String>[];
      final (container, _, ctl) = await seedPipeline(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }, gatewayAlive: true);
      staleHandshake(ctl);
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 0);
      expect(state.healthNote, isNull);
      expect(events, isEmpty);
    });

    test('gateway dead plus api up fast-tracks to failover', () async {
      final events = <String>[];
      final (container, _, ctl) = await seedPipeline(events, (o) {
        // Initial connect (events are cleared before the tick).
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/vpn-regions')) {
          return [
            {
              'id': 'r1',
              'name': 'R1',
              'country_code': null,
              'servers': [
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
              ],
            },
          ];
        }
        if (o.path.endsWith('/switch')) {
          return dialJson(serverId: 'srv-2', serverName: 'two');
        }
        throw StateError('unexpected ${o.path}');
      }, apiReachable: true);
      staleHandshake(ctl);
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      // No offline heal burned and no config fetch: straight to a server
      // move, with the path-dead tunnel stopped before discovery.
      expect(state.autoHealAttempts, 0);
      expect(state.autoFailoverAttempts, 1);
      expect(state.dial?.serverId, 'srv-2');
      expect(events, contains('GET:/vpn-regions'));
      expect(events, contains('POST:/vpn-devices/dev-1/switch'));
      expect(events.where((e) => e.startsWith('tunnel:')), [
        'tunnel:stop',
        'tunnel:start',
      ]);
      expect(events, isNot(contains('GET:/vpn-devices/dev-1/config')));
    });

    test('gateway and api dead keeps the legacy offline heal', () async {
      final events = <String>[];
      final (container, _, ctl) = await seedPipeline(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      });
      staleHandshake(ctl);
      await ctl.checkHealthOnce();

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      expect(state.autoHealAttempts, 1);
      expect(events.where((e) => e.startsWith('tunnel:')), [
        'tunnel:stop',
        'tunnel:start',
      ]);
      expect(events.where((e) => e.startsWith('GET:')), isEmpty);
    });
  });
}
