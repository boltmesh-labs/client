import 'dart:async';

import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef _Store = support.FakeDeviceStore;
typedef _Keys = support.FakeKeys;

class _AuthDouble extends AuthController {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated);

  void revoke() => snap = const AsyncData(AuthState());

  void authenticateAgain() =>
      snap = const AsyncData(AuthState(status: AuthStatus.authenticated));
}

class _Tunnel extends support.FakeTunnel {
  _Tunnel(List<String> events) : super(events: events);
}

Future<(ProviderContainer, _AuthDouble, _Store, List<String>)>
connected() async {
  final events = <String>[];
  final store = _Store();
  final auth = _AuthDouble();
  final api = VpnApi(
    recordingDio(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      throw StateError('unexpected ${o.path}');
    }),
  );
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => auth),
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(_Keys()),
      vpnApiProvider.overrideWithValue(api),
      networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
      gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
      controlPlaneProbeProvider.overrideWithValue(DownControlProbe()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(authProvider.future);
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = _Tunnel(events);
  await ctl.connect();
  events.clear();
  return (container, auth, store, events);
}

void main() {
  test('session revocation teardown waits for the operation mutex', () async {
    final (container, auth, store, events) = await connected();
    final ctl = container.read(connectionProvider.notifier);
    final cleared = Completer<void>();
    store.clearDeviceHook = () async => cleared.complete();

    final release = await ctl.debugAcquireMutex('test-auth-race');
    auth.revoke();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(connectionProvider).phase, ConnPhase.idle);
    expect(events, isEmpty);
    expect(await store.deviceId(), 'dev-1');

    release();
    await cleared.future;
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('tunnel:stop'));
    expect(await store.deviceId(), isNull);
  });

  test(
    'an invalidated connect cannot publish a tunnel after revocation',
    () async {
      final events = <String>[];
      final store = _Store();
      final auth = _AuthDouble();
      final api = VpnApi(
        recordingDio(events, (o) {
          if (o.path.endsWith('/config')) return dialJson();
          throw StateError('unexpected ${o.path}');
        }),
      );
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(() => auth),
          deviceStoreProvider.overrideWithValue(store),
          keyManagerProvider.overrideWithValue(_Keys()),
          vpnApiProvider.overrideWithValue(api),
          networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
          gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
          controlPlaneProbeProvider.overrideWithValue(DownControlProbe()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authProvider.future);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');

      final started = Completer<void>();
      final releaseStart = Completer<void>();
      final tunnel = _Tunnel(events)
        ..onStart = () async {
          if (!started.isCompleted) started.complete();
          await releaseStart.future;
        };
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = tunnel;

      final connect = ctl.connect();
      await started.future;
      auth.revoke();
      auth.authenticateAgain();
      releaseStart.complete();
      await connect;
      await Future<void>.delayed(Duration.zero);

      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      expect(await store.deviceId(), isNull);
      expect(events.where((event) => event == 'tunnel:start'), hasLength(1));
    },
  );
}
