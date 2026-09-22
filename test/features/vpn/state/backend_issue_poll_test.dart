import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;
import '../../../support/vpn_harness.dart';

typedef FakeStore = support.FakeDeviceStore;

/// 401 with the session token expired/revoked.
DioException authExpired401(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 401,
    data: const {'detail': 'Not authenticated'},
  ),
  error: const ApiException(
    ApiErrorKind.unauthorized,
    'Session expired. Please log in again.',
    401,
  ),
);

/// 403 with no active subscription.
DioException noSubscription403(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 403,
    data: const {'detail': 'No active subscription'},
  ),
  error: const ApiException(
    ApiErrorKind.forbiddenNoSubscription,
    'No active subscription. Renew to connect.',
    403,
  ),
);

ProviderContainer makeContainer({
  required FakeStore store,
  required VpnApi api,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(support.FakeKeys(const [])),
      vpnApiProvider.overrideWithValue(api),
      networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
      gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
      controlPlaneProbeProvider.overrideWithValue(DownControlProbe()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<(ProviderContainer, support.FakeTunnel)> seedConnected(
  List<String> events,
  dynamic Function(RequestOptions options) respond,
) async {
  final store = FakeStore();
  final api = VpnApi(recordingDio(events, respond));
  final container = makeContainer(store: store, api: api);
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final tunnel = support.FakeTunnel(events: events);
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  ctl.debugHandshakeReader = () async => DateTime.now();
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
  events.clear();
  return (container, tunnel);
}

void main() {
  test('401 surfaces authExpired, never unreachable', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw authExpired401(o);
      throw StateError('unexpected ${o.path}');
    });

    await container.read(connectionProvider.notifier).pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.backendIssue, BackendIssue.authExpired);
    // An answered 401 proves reachability, so it never escalates the ladder.
    expect(state.pollFailures, 0);
    expect(state.healthNote, isNull);
  });

  test('a 401 replaces a stale transport-unreachable note', () async {
    final events = <String>[];
    var mode = 'transport';
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        if (mode == 'transport') throw networkTimeout(o);
        throw authExpired401(o);
      }
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    for (var i = 0; i < 3; i++) {
      await ctl.pollStatusOnce();
    }
    expect(
      container.read(connectionProvider).healthNote,
      contains('Backend unreachable'),
    );

    // The backend answers 401: reachability is proven, so the network note
    // must not outlive the transport outage it described.
    mode = 'auth';
    await ctl.pollStatusOnce();
    final state = container.read(connectionProvider);
    expect(state.backendIssue, BackendIssue.authExpired);
    expect(state.healthNote, isNull);
  });

  test('403 subscription lapse surfaces subscriptionInactive', () async {
    final events = <String>[];
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) throw noSubscription403(o);
      throw StateError('unexpected ${o.path}');
    });

    await container.read(connectionProvider.notifier).pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.backendIssue, BackendIssue.subscriptionInactive);
    expect(state.pollFailures, 0);
  });

  test('5xx surfaces serverError and keeps the degraded note', () async {
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

    await container.read(connectionProvider.notifier).pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.backendIssue, BackendIssue.serverError);
    expect(state.healthNote, contains('Backend error (500)'));
  });

  test(
    'transport failures surface unreachable at the degraded threshold',
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
      expect(state.backendIssue, isNull);
      expect(state.healthNote, isNull);

      await ctl.pollStatusOnce();
      state = container.read(connectionProvider);
      expect(state.backendIssue, BackendIssue.unreachable);
      expect(state.pollFailures, 3);
      expect(state.healthNote, contains('Backend unreachable'));
    },
  );

  test('a successful poll clears the structured issue', () async {
    final events = <String>[];
    var fail = true;
    final (container, _) = await seedConnected(events, (o) {
      if (o.path.endsWith('/config')) return dialJson();
      if (o.path.endsWith('/status')) {
        if (fail) throw authExpired401(o);
        return activeStatusJson();
      }
      throw StateError('unexpected ${o.path}');
    });
    final ctl = container.read(connectionProvider.notifier);

    await ctl.pollStatusOnce();
    expect(
      container.read(connectionProvider).backendIssue,
      BackendIssue.authExpired,
    );

    fail = false;
    await ctl.pollStatusOnce();
    expect(container.read(connectionProvider).backendIssue, isNull);
  });
}
