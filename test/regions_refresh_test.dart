import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/auth/data/session_store.dart';
import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:boltmesh/features/vpn/data/backend_health.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConnectionController extends ConnectionController {
  @override
  ConnState build() => const ConnState();

  @override
  Future<void> ensureProvisioned({String? regionId, String? serverId}) async {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> quickConnect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> switchServer({
    required String? regionId,
    required String? serverId,
    bool explicitTarget = true,
    bool pinTarget = true,
  }) async {}

  @override
  Future<void> selectAuto() async {}
}

class _FakeSessionStore extends SessionStore {
  const _FakeSessionStore();

  @override
  Future<String?> apiToken() async => null;

  @override
  Future<String?> refreshToken() async => null;

  @override
  Future<DateTime?> accessExpiry() async => null;

  @override
  Future<String?> authUsername() async => null;
}

class _FakeDeviceStore extends DeviceStore {
  _FakeDeviceStore();

  @override
  Future<String?> deviceName() async => null;

  @override
  Future<bool> allowLocal() async => true;

  @override
  Future<void> setAllowLocal(bool v) async {}
}

class _AuthedController extends AuthController {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, username: 'tester');
}

/// Counting `/vpn-regions` stub: records every discovery fetch and either
/// serves one region or fails, flipped via [fail].
class _CountingRegionsApi {
  _CountingRegionsApi() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/vpn-regions') {
            calls++;
            if (fail) {
              handler.reject(
                DioException(requestOptions: options, error: 'boom'),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: [
                    {
                      'id': 'r-1',
                      'name': 'Testland',
                      'country_code': 'TL',
                      'servers': [
                        {
                          'id': 's-1',
                          'name': 'one',
                          'endpoint': 'one.example.com',
                          'wg_port': 51820,
                        },
                      ],
                    },
                  ],
                ),
              );
            }
            return;
          }
          handler.next(options);
        },
      ),
    );
    api = VpnApi(dio);
  }

  late final VpnApi api;
  int calls = 0;
  bool fail = false;
}

ProviderScope _regionsScope(_CountingRegionsApi stub) {
  return ProviderScope(
    // Disable the framework's automatic retry (up to 10x with backoff):
    // it advances with fake-async time during pumpAndSettle and would make
    // fetch counts nondeterministic. Production keeps the default.
    retry: (_, _) => null,
    overrides: [
      backendHealthProvider.overrideWith(
        (ref) => Stream.value(BackendHealth.reachable),
      ),
      connectionProvider.overrideWith(_FakeConnectionController.new),
      deviceStoreProvider.overrideWithValue(_FakeDeviceStore()),
      sessionStoreProvider.overrideWithValue(const _FakeSessionStore()),
      authProvider.overrideWith(_AuthedController.new),
      vpnApiProvider.overrideWithValue(stub.api),
    ],
    child: const BoltMeshApp(),
  );
}

Future<void> _openRegions(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(NavigationDestination, 'Regions'));
  await tester.pumpAndSettle();
}

Future<void> _openConnect(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(NavigationDestination, 'Connect'));
  await tester.pumpAndSettle();
}

/// Lets the [Env.regionsCacheTtl] keep-alive timer fire (the provider stays
/// mounted, so the fetch itself is not repeated): without this the pending
/// timer fails test teardown.
Future<void> _settleKeepAliveTimer(WidgetTester tester) async {
  await tester.pump(Env.regionsCacheTtl + const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('region list survives tab switches without refetching', (
    tester,
  ) async {
    final stub = _CountingRegionsApi();
    await tester.pumpWidget(_regionsScope(stub));
    await tester.pumpAndSettle();

    // The shell keeps every tab mounted (IndexedStack), so discovery ran
    // once at startup — before Regions was ever selected.
    await _openRegions(tester);
    expect(find.text('Testland'), findsOneWidget);
    expect(stub.calls, 1);

    await _openConnect(tester);
    expect(find.text('Disconnected'), findsOneWidget);
    await _openRegions(tester);
    expect(find.text('Testland'), findsOneWidget);
    // Re-selecting the tab must not refetch (the state was preserved).
    expect(stub.calls, 1);

    // Even past the cache TTL: the mounted tab holds the provider alive.
    await _settleKeepAliveTimer(tester);
    expect(stub.calls, 1);
  });

  testWidgets('failed discovery shows an error with a working retry', (
    tester,
  ) async {
    final stub = _CountingRegionsApi()..fail = true;
    await tester.pumpWidget(_regionsScope(stub));
    await tester.pumpAndSettle();

    await _openRegions(tester);
    expect(find.text('Testland'), findsNothing);
    // Generic copy with a retry affordance — never a raw exception.
    expect(find.textContaining("Couldn't load regions"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    stub.fail = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Testland'), findsOneWidget);

    await _settleKeepAliveTimer(tester);
  });

  testWidgets('manual refresh refetches and snacks', (tester) async {
    final stub = _CountingRegionsApi();
    await tester.pumpWidget(_regionsScope(stub));
    await tester.pumpAndSettle();

    await _openRegions(tester);
    expect(find.text('Testland'), findsOneWidget);
    expect(stub.calls, 1);

    await tester.tap(find.byKey(const Key('refreshRegions')));
    await tester.pumpAndSettle();
    expect(stub.calls, 2);
    expect(find.text('Regions updated (1 regions)'), findsOneWidget);
    expect(find.text('Testland'), findsOneWidget);

    await _settleKeepAliveTimer(tester);
  });
}
