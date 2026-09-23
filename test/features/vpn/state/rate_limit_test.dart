import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
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

/// 429 rejection shaped like the shared Dio interceptor would produce,
/// carrying the parsed `Retry-After` wait (null = header absent).
DioException rateLimited(RequestOptions o, {int? seconds = 60}) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 429,
    data: const {
      'detail': 'Rate limit exceeded. Please try again later.',
      'code': 'RATE_LIMIT_EXCEEDED',
    },
  ),
  error: ApiException(
    ApiErrorKind.rateLimited,
    'Rate limit exceeded. Please try again later.',
    429,
    'RATE_LIMIT_EXCEEDED',
    seconds == null ? null : Duration(seconds: seconds),
  ),
);

ProviderContainer makeContainer({
  required FakeStore store,
  required VpnApi api,
  support.FakeClock? clock,
}) {
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(FakeKeys()),
      vpnApiProvider.overrideWithValue(api),
      networkMonitorProvider.overrideWithValue(
        support.FakeNetworkMonitor(true),
      ),
      clockProvider.overrideWithValue(clock ?? support.FakeClock()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('429 on status arms the client cooldown', () async {
    final events = <String>[];
    final store = FakeStore();
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        if (o.path.endsWith('/status')) throw rateLimited(o, seconds: 5);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, api: api);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    await ctl.connect();

    await ctl.pollStatusOnce();

    final state = container.read(connectionProvider);
    expect(state.pollFailures, 0);
    expect(state.backendIssue, BackendIssue.serverError);
    expect(ctl.debugRateLimitedUntil, isNotNull);
  });

  test('429 on connect arms a cooldown and skips the next attempt', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) throw peerless(o);
        if (o.path.endsWith('/connect')) throw rateLimited(o, seconds: 5);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, api: api);
    final ctl = container.read(connectionProvider.notifier);

    await ctl.connect();

    final first = container.read(connectionProvider);
    expect(first.phase, ConnPhase.error);
    expect(first.opFailed, isTrue);
    // 5s Retry-After + 1s buffer.
    expect(first.message, 'Rate limit reached. Please wait 6s.');
    expect(events, contains('POST:/vpn-devices/dev-1/connect'));

    final callsAfterFirst = events.length;
    await ctl.connect();

    // The cooldown short-circuits before any HTTP call.
    expect(events.length, callsAfterFirst);
    final second = container.read(connectionProvider);
    expect(second.opFailed, isTrue);
    expect(second.message, 'Rate limit reached. Please wait 6s.');
  });

  test('a 429 without Retry-After falls back to the 60s default', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) throw peerless(o);
        if (o.path.endsWith('/connect')) throw rateLimited(o, seconds: null);
        throw StateError('unexpected ${o.path}');
      }),
    );
    final container = makeContainer(store: store, api: api);
    final ctl = container.read(connectionProvider.notifier);

    await ctl.connect();

    expect(
      container.read(connectionProvider).message,
      'Rate limit reached. Please wait 61s.',
    );
  });

  test('the cooldown expires and lets the next connect through', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    var limited = true;
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) throw peerless(o);
        if (o.path.endsWith('/connect')) {
          if (limited) throw rateLimited(o, seconds: 5);
          return dialJson();
        }
        throw StateError('unexpected ${o.path}');
      }),
    );
    final clock = support.FakeClock();
    final container = makeContainer(store: store, api: api, clock: clock);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    await ctl.connect();
    expect(container.read(connectionProvider).message, contains('Please wait'));

    limited = false;
    clock.advance(const Duration(seconds: 7));
    await ctl.connect();

    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.opFailed, isFalse);
    expect(events, contains('tunnel:start'));
  });

  test('a throttled disconnect skips the POST and stays local', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    final api = VpnApi(
      recordingDio(events, (o) => throw StateError('unexpected ${o.path}')),
    );
    final clock = support.FakeClock();
    final container = makeContainer(store: store, api: api, clock: clock);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);
    ctl.debugRateLimitedUntil = clock.now().add(const Duration(seconds: 30));

    await ctl.disconnect();

    expect(
      events.any((e) => e.contains('/disconnect')),
      isFalse,
      reason: 'the peer-release POST must be skipped during a cooldown',
    );
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.idle);
    expect(state.message, contains('Server release pending'));
    expect(state.message, contains('rate limited'));
  });

  test('a throttled switch keeps the live tunnel and flags feedback', () async {
    final events = <String>[];
    final store = FakeStore();
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'P', publicKey: 'PUB');
    final api = VpnApi(
      recordingDio(events, (o) {
        if (o.path.endsWith('/config')) return dialJson();
        throw StateError('unexpected ${o.path}');
      }),
    );
    final clock = support.FakeClock();
    final container = makeContainer(store: store, api: api, clock: clock);
    final ctl = container.read(connectionProvider.notifier);
    ctl.debugTunnel = FakeTunnel(events);

    await ctl.connect();
    expect(container.read(connectionProvider).phase, ConnPhase.connected);
    final callsAfterConnect = events.length;

    ctl.debugRateLimitedUntil = clock.now().add(const Duration(seconds: 30));
    await ctl.switchServer(regionId: null, serverId: 'srv-2');

    expect(events.length, callsAfterConnect);
    final state = container.read(connectionProvider);
    expect(state.phase, ConnPhase.connected);
    expect(state.opFailed, isTrue);
    expect(state.message, contains('Rate limit reached'));
  });
}
