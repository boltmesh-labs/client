import 'dart:async';

import 'package:boltmesh/features/auth/data/auth_api.dart';
import 'package:boltmesh/features/auth/data/session_store.dart';
import 'package:boltmesh/features/auth/state/auth_providers.dart';
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

// --- Auth fakes (mirrors auth_controller_test.dart, kept local) ---

class ResumeAuthStore extends SessionStore {
  ResumeAuthStore() : super();
  final _m = <String, String>{};

  @override
  Future<String?> apiToken() async => _m['access'];
  @override
  Future<String?> refreshToken() async => _m['refresh'];
  @override
  Future<DateTime?> accessExpiry() async {
    final raw = _m['expiry'];
    return raw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(raw), isUtc: true);
  }

  @override
  Future<String?> authUsername() async => _m['user'];
  @override
  Future<void> setAuth({
    required String accessToken,
    required DateTime expiresAt,
    String? refreshToken,
    String? username,
  }) async {
    _m['access'] = accessToken;
    _m['expiry'] = expiresAt.toUtc().millisecondsSinceEpoch.toString();
    if (refreshToken != null) {
      _m['refresh'] = refreshToken;
    } else {
      _m.remove('refresh');
    }
    if (username != null) {
      _m['user'] = username;
    } else {
      _m.remove('user');
    }
  }

  @override
  Future<void> clearAuth() async => _m
    ..remove('access')
    ..remove('refresh')
    ..remove('expiry')
    ..remove('user');
}

Dio resumeAuthDio(Map<String, int> calls) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        calls.update(options.path, (v) => v + 1, ifAbsent: () => 1);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: const {
              'access_token': 'access-2',
              'token_type': 'bearer',
              'expires_in': 900,
              'refresh_expires_in': 604800,
            },
            headers: Headers.fromMap({
              'set-cookie': ['refresh_token=r-new; Path=/v1/auth'],
            }),
          ),
        );
      },
    ),
  );
  return dio;
}

ProviderContainer makeResumeAuthContainer(
  ResumeAuthStore store,
  Map<String, int> calls,
) {
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(store),
      authApiProvider.overrideWithValue(AuthApi(resumeAuthDio(calls))),
      nativeLoopbackProvider.overrideWith((_) async => null),
    ],
  );
  addTearDown(() {
    try {
      container.read(authProvider.notifier).debugCancelTimer();
    } catch (_) {}
    container.dispose();
  });
  return container;
}

// --- VPN fakes (shared harness + resume-specific tunnel) ---

typedef ResumeDeviceStore = support.FakeDeviceStore;
typedef ResumeKeys = support.FakeKeys;

class ResumeTunnel extends support.FakeTunnel {
  ResumeTunnel() : super(traffic: const {'rx': 1000});
}

Dio resumeVpnDio(List<String> events) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
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
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: activeStatusJson(),
            ),
          );
          return;
        }
        if (options.path.endsWith('/disconnect')) {
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: ''),
          );
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
  return dio;
}

Future<(ProviderContainer, ResumeTunnel)> seedResumeConnected(
  List<String> events,
) async {
  final store = ResumeDeviceStore();
  final container = ProviderContainer(
    overrides: [
      deviceStoreProvider.overrideWithValue(store),
      keyManagerProvider.overrideWithValue(ResumeKeys()),
      vpnApiProvider.overrideWithValue(VpnApi(resumeVpnDio(events))),
      // Legacy total-blackout pipeline path: deterministic, no real I/O.
      networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
      gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
      controlPlaneProbeProvider.overrideWithValue(DownControlProbe()),
    ],
  );
  addTearDown(container.dispose);
  await store.setDeviceId('dev-1');
  await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
  final tunnel = ResumeTunnel();
  final ctl = container.read(connectionProvider.notifier);
  ctl.debugTunnel = tunnel;
  await ctl.connect();
  expect(container.read(connectionProvider).phase, ConnPhase.connected);
  events.clear();
  return (container, tunnel);
}

int statusCalls(List<String> events) =>
    events.where((e) => e.endsWith('/status')).length;

void main() {
  group('AuthController.refreshIfExpired', () {
    test('expired access triggers one refresh', () async {
      final calls = <String, int>{};
      final store = ResumeAuthStore();
      await store.setAuth(
        accessToken: 'old',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        refreshToken: 'r0',
        username: 'u',
      );
      final container = makeResumeAuthContainer(store, calls);
      // Restore consumes its own refresh and stores a fresh expiry; re-age
      // the token so the resume path sees an expiry missed while suspended.
      await container.read(authProvider.future);
      await store.setAuth(
        accessToken: 'aged',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        refreshToken: 'r1',
        username: 'u',
      );
      calls.clear();

      final ok = await container
          .read(authProvider.notifier)
          .refreshIfExpired(now: DateTime.now());

      expect(ok, isTrue);
      expect(calls['/auth/refresh-token'], 1);
      expect(await store.apiToken(), 'access-2');
    });

    test('valid access skips the network', () async {
      final calls = <String, int>{};
      final store = ResumeAuthStore();
      await store.setAuth(
        accessToken: 'cached',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        refreshToken: 'r0',
        username: 'u',
      );
      final container = makeResumeAuthContainer(store, calls);
      await container.read(authProvider.future);
      expect(calls, isEmpty);

      final ok = await container
          .read(authProvider.notifier)
          .refreshIfExpired(now: DateTime.now());

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('unauthenticated skips the network', () async {
      final calls = <String, int>{};
      final store = ResumeAuthStore();
      final container = makeResumeAuthContainer(store, calls);
      final restored = await container.read(authProvider.future);
      expect(restored.status, AuthStatus.unauthenticated);

      final ok = await container
          .read(authProvider.notifier)
          .refreshIfExpired(now: DateTime.now());

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('ConnectionController.catchUpOnResume (Option A)', () {
    test('stale status runs health + status', () async {
      final events = <String>[];
      final (container, _) = await seedResumeConnected(events);
      final ctl = container.read(connectionProvider.notifier);
      // Fresh connect leaves lastStatusAt null -> stale by definition.
      expect(container.read(connectionProvider).lastStatusAt, isNull);

      await ctl.catchUpOnResume(now: DateTime.now());

      final state = container.read(connectionProvider);
      expect(state.phase, ConnPhase.connected);
      // Health tick ran locally (counters published from the fake tunnel).
      expect(state.rxBytes, isNotNull);
      // Status poll ran once (snapshot refreshed).
      expect(statusCalls(events), 1);
      expect(state.lastStatusAt, isNotNull);
    });

    test('resume shares an in-flight status tick', () async {
      final events = <String>[];
      final statusStarted = Completer<void>();
      final releaseStatus = Completer<void>();
      final store = ResumeDeviceStore();
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
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: activeStatusJson(),
                ),
              );
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
      final container = ProviderContainer(
        overrides: [
          deviceStoreProvider.overrideWithValue(store),
          keyManagerProvider.overrideWithValue(ResumeKeys()),
          vpnApiProvider.overrideWithValue(VpnApi(dio)),
          networkMonitorProvider.overrideWithValue(OnlineNetworkMonitor()),
          gatewayProbeProvider.overrideWithValue(DeadGatewayProbe()),
          controlPlaneProbeProvider.overrideWithValue(DownControlProbe()),
        ],
      );
      addTearDown(container.dispose);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'OLD-PRIV', publicKey: 'OLD-PUB');
      final ctl = container.read(connectionProvider.notifier);
      ctl.debugTunnel = ResumeTunnel();
      await ctl.connect();
      events.clear();

      final poll = ctl.pollStatusOnce();
      await statusStarted.future;
      final resume = ctl.catchUpOnResume(now: DateTime.now());
      await Future<void>.delayed(Duration.zero);
      expect(statusCalls(events), 1);

      releaseStatus.complete();
      await poll;
      await resume;
      expect(statusCalls(events), 1);
    });

    test('fresh status runs health only', () async {
      final events = <String>[];
      final (container, _) = await seedResumeConnected(events);
      final ctl = container.read(connectionProvider.notifier);

      await ctl.pollStatusOnce();
      expect(statusCalls(events), 1);
      events.clear();

      await ctl.catchUpOnResume(now: DateTime.now());

      // Health still runs (rx counters present) but no extra status POST.
      expect(container.read(connectionProvider).rxBytes, isNotNull);
      expect(statusCalls(events), 0);
    });

    test('idle does nothing', () async {
      final events = <String>[];
      final (container, _) = await seedResumeConnected(events);
      final ctl = container.read(connectionProvider.notifier);
      await ctl.disconnect();
      expect(container.read(connectionProvider).phase, ConnPhase.idle);
      events.clear();

      await ctl.catchUpOnResume(now: DateTime.now());

      expect(statusCalls(events), 0);
    });

    test('locked mutex skips without network', () async {
      final events = <String>[];
      final (container, _) = await seedResumeConnected(events);
      final ctl = container.read(connectionProvider.notifier);
      final release = await ctl.debugAcquireMutex();
      try {
        await ctl.catchUpOnResume(now: DateTime.now());
      } finally {
        release();
      }

      expect(statusCalls(events), 0);
    });
  });
}
