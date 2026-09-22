import 'dart:async';
import 'dart:convert';

import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/auth/data/auth_api.dart';
import 'package:boltmesh/features/auth/data/session_store.dart';
import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

class FakeAuthStore extends SessionStore {
  FakeAuthStore() : super();
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

Map<String, dynamic> tokenJson({int expiresIn = 900}) => {
  'access_token': 'access-1',
  'token_type': 'bearer',
  'expires_in': expiresIn,
  'refresh_expires_in': 604800,
};

DioException revoked(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 401,
    data: const {'detail': 'Invalid or expired token.'},
  ),
  error: const ApiException(
    ApiErrorKind.unauthorized,
    'Session expired. Please log in again.',
    401,
  ),
);

/// Fake session backend: counts calls per path, answers login/refresh with
/// [tokenJson] + rotating cookies, logout with 204.
Dio fakeSessionDio(
  Map<String, int> calls, {
  DioException Function(RequestOptions options)? failOn,
  int expiresIn = 900,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        calls.update(options.path, (v) => v + 1, ifAbsent: () => 1);
        final fail = failOn?.call(options);
        if (fail != null) {
          handler.reject(fail);
          return;
        }
        if (options.path == '/auth/logout') {
          handler.resolve(
            Response(requestOptions: options, statusCode: 204, data: ''),
          );
          return;
        }
        if (options.path == '/users') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: const {'username': 'octocat'},
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: tokenJson(expiresIn: expiresIn),
            headers: Headers.fromMap({
              'set-cookie': [
                'refresh_token=r${calls[options.path]}; Path=/v1/auth',
              ],
            }),
          ),
        );
      },
    ),
  );
  return dio;
}

/// Dio whose `POST /auth/refresh-token` can be held pending on demand, so a
/// test can log out while the refresh is still in flight.
class GatedAuthDio {
  GatedAuthDio(this.calls);

  final Map<String, int> calls;
  Completer<void>? refreshGate;

  Dio build() {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          calls.update(options.path, (v) => v + 1, ifAbsent: () => 1);
          final gate = refreshGate;
          if (options.path == '/auth/refresh-token' && gate != null) {
            await gate.future;
          }
          if (options.path == '/auth/logout') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 204, data: ''),
            );
            return;
          }
          if (options.path == '/users') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: const {'username': 'octocat'},
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: tokenJson(),
              headers: Headers.fromMap({
                'set-cookie': ['refresh_token=r1; Path=/v1/auth'],
              }),
            ),
          );
        },
      ),
    );
    return dio;
  }
}

ProviderContainer makeAuthContainer(
  FakeAuthStore store,
  Dio dio, {
  Map<String, int>? calls,
  OAuthAuthenticate? oauthBrowser,
  String? loopback,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(store),
      authApiProvider.overrideWithValue(AuthApi(dio)),
      // Default is the mobile path (no loopback); desktop tests pass an
      // explicit loopback URL so the real socket bind never runs on the VM.
      nativeLoopbackProvider.overrideWith((_) async => loopback),
      if (oauthBrowser != null)
        oauthAuthenticateProvider.overrideWithValue(oauthBrowser),
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

/// Awaits the startup session-restore (now [AuthController.build] itself),
/// so tests start from a settled `authenticated`/`unauthenticated` value
/// instead of racing the initial loading state.
Future<AuthState> settleRestore(ProviderContainer container) =>
    container.read(authProvider.future);

void main() {
  test('login stores session and authenticates', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    final container = makeAuthContainer(store, fakeSessionDio(calls));
    await settleRestore(container);

    await container
        .read(authProvider.notifier)
        .login(identifier: ' John@Example.com ', password: 'Secret123');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.authenticated);
    // The display name is resolved via GET /users, not the typed identifier
    // (which may be an email or differently-cased username).
    expect(state.username, 'octocat');
    expect(state.working, isFalse);
    expect(state.error, isNull);
    expect(await store.apiToken(), 'access-1');
    expect(await store.refreshToken(), isNotNull);
    expect(await store.accessExpiry(), isNotNull);
    expect(await store.authUsername(), 'octocat');
    expect(calls['/auth/login'], 1);
    expect(calls['/users'], 1);
  });

  test('login falls back to the typed identifier when lookup fails', () async {
    final store = FakeAuthStore();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/users') {
            handler.reject(revoked(options));
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: tokenJson(),
              headers: Headers.fromMap({
                'set-cookie': ['refresh_token=r1; Path=/v1/auth'],
              }),
            ),
          );
        },
      ),
    );
    final container = makeAuthContainer(store, dio);
    await settleRestore(container);

    await container
        .read(authProvider.notifier)
        .login(identifier: ' John@Example.com ', password: 'Secret123');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.authenticated);
    expect(state.username, 'John@Example.com');
    expect(await store.authUsername(), 'John@Example.com');
  });

  test('login failure surfaces bad-credentials message', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    final container = makeAuthContainer(
      store,
      fakeSessionDio(calls, failOn: revoked),
    );
    await settleRestore(container);

    await container
        .read(authProvider.notifier)
        .login(identifier: 'u', password: 'wrong');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.error, 'Incorrect username, email, or password.');
    expect(await store.apiToken(), isNull);
  });

  test('concurrent refresh shares one POST (single-flight)', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    await store.setAuth(
      accessToken: 'old',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      refreshToken: 'r0',
      username: 'u',
    );
    final container = makeAuthContainer(store, fakeSessionDio(calls));
    // Restore itself consumes the first refresh; clear it so the assertions
    // below measure only the two concurrent runtime callers sharing one POST.
    await settleRestore(container);
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.authenticated,
    );
    calls.clear();

    final results = await Future.wait([
      container.read(authProvider.notifier).refreshForRetry(),
      container.read(authProvider.notifier).refreshForRetry(),
    ]);

    expect(results, [true, true]);
    expect(calls['/auth/refresh-token'], 1);
    expect(await store.apiToken(), 'access-1');
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.authenticated,
    );
  });

  test('revoked refresh signs out and clears storage', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    await store.setAuth(
      accessToken: 'old',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      refreshToken: 'stale',
      username: 'u',
    );
    final container = makeAuthContainer(
      store,
      fakeSessionDio(calls, failOn: (o) => revoked(o)),
    );
    // Restore attempts the refresh, hits 401, and signs out.
    final restored = await settleRestore(container);
    expect(restored.status, AuthStatus.unauthenticated);
    expect(await store.apiToken(), isNull);
    expect(await store.refreshToken(), isNull);

    // A later retry finds no refresh token and stays signed out without
    // another network call.
    expect(
      await container.read(authProvider.notifier).refreshForRetry(),
      isFalse,
    );
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.unauthenticated,
    );
    expect(calls['/auth/refresh-token'], 1);
  });

  test('logout revokes server-side and clears local session', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    final container = makeAuthContainer(store, fakeSessionDio(calls));
    await settleRestore(container);
    await container
        .read(authProvider.notifier)
        .login(identifier: 'u', password: 'p');
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.authenticated,
    );

    await container.read(authProvider.notifier).logout();

    expect(calls['/auth/logout'], 1);
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.unauthenticated,
    );
    expect(await store.apiToken(), isNull);
    expect(await store.refreshToken(), isNull);
  });

  test('logout drops a refresh that was already in flight', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    await store.setAuth(
      accessToken: 'old',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      refreshToken: 'r0',
      username: 'u',
    );
    final gated = GatedAuthDio(calls);
    final container = makeAuthContainer(store, gated.build());
    // Startup restore consumes the first refresh (gate is null), leaving an
    // authenticated session.
    await settleRestore(container);
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.authenticated,
    );
    calls.clear();

    gated.refreshGate = Completer<void>();
    final refresh = container.read(authProvider.notifier).refreshForRetry();
    // Log out while the refresh POST is still pending.
    await container.read(authProvider.notifier).logout();
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.unauthenticated,
    );

    gated.refreshGate!.complete();
    expect(await refresh, isFalse);
    // The late refresh must not resurrect the session or rewrite its tokens.
    expect(
      container.read(authProvider).requireValue.status,
      AuthStatus.unauthenticated,
    );
    expect(await store.apiToken(), isNull);
    expect(await store.refreshToken(), isNull);
  });

  test('restore with valid stored tokens skips the network', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    await store.setAuth(
      accessToken: 'cached',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      refreshToken: 'r0',
      username: 'cached-user',
    );
    final container = makeAuthContainer(store, fakeSessionDio(calls));
    // Startup restore runs in build(); awaiting its future settles it.
    final state = await settleRestore(container);

    expect(state.status, AuthStatus.authenticated);
    expect(state.username, 'cached-user');
    expect(calls, isEmpty);
  });

  test('oauth sign-in exchanges code and resolves username', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    var seenUrl = '';
    final container = makeAuthContainer(
      store,
      fakeSessionDio(calls),
      oauthBrowser:
          ({
            required String url,
            required String callbackUrlScheme,
            FlutterWebAuth2Options? options,
          }) async {
            seenUrl = url;
            expect(callbackUrlScheme, 'boltmesh');
            expect(options, isNull);
            return 'boltmesh://auth/callback?code=abc123';
          },
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('github');

    expect(seenUrl, contains('/auth/github?platform=native&remember_me=true'));
    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.authenticated);
    expect(state.username, 'octocat');
    expect(await store.apiToken(), 'access-1');
    expect(await store.refreshToken(), isNotNull);
    expect(calls['/auth/native/exchange'], 1);
    expect(calls['/users'], 1);
  });

  test('oauth sign-in binds an app PKCE pair to the exchange', () async {
    final store = FakeAuthStore();
    RequestOptions? exchange;
    var authorizeUrl = '';
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/auth/native/exchange') exchange = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: tokenJson(),
              headers: Headers.fromMap({
                'set-cookie': ['refresh_token=r1; Path=/v1/auth'],
              }),
            ),
          );
        },
      ),
    );
    final container = makeAuthContainer(
      store,
      dio,
      oauthBrowser:
          ({
            required String url,
            required String callbackUrlScheme,
            FlutterWebAuth2Options? options,
          }) async {
            authorizeUrl = url;
            return 'boltmesh://auth/callback?code=abc123';
          },
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    final query = Uri.parse(authorizeUrl).queryParameters;
    expect(query['code_challenge_method'], 'S256');
    final challenge = query['code_challenge']!;
    expect(exchange, isNotNull);
    final verifier = (exchange!.data as Map)['code_verifier'] as String;
    final expected = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    expect(challenge, expected);
    expect(await store.refreshToken(), isNotNull);
  });

  test('oauth error param is sanitized before display', () async {
    final store = FakeAuthStore();
    final container = makeAuthContainer(
      store,
      fakeSessionDio(const {}),
      oauthBrowser:
          ({
            required String url,
            required String callbackUrlScheme,
            FlutterWebAuth2Options? options,
          }) async =>
              'boltmesh://auth/callback'
              '?error=${Uri.encodeComponent('bad\u0000\nnews')}',
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.error, 'badnews');
  });

  test('oauth desktop loopback uses the external-browser flow', () async {
    final calls = <String, int>{};
    final store = FakeAuthStore();
    const loopback = 'http://127.0.0.1:54321/callback';
    var seenUrl = '';
    var seenScheme = '';
    FlutterWebAuth2Options? seenOptions;
    final container = makeAuthContainer(
      store,
      fakeSessionDio(calls),
      loopback: loopback,
      oauthBrowser:
          ({
            required String url,
            required String callbackUrlScheme,
            FlutterWebAuth2Options? options,
          }) async {
            seenUrl = url;
            seenScheme = callbackUrlScheme;
            seenOptions = options;
            return '$loopback?code=abc123';
          },
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    expect(
      seenUrl,
      contains('native_callback=http%3A%2F%2F127.0.0.1%3A54321%2Fcallback'),
    );
    expect(seenScheme, loopback);
    expect(seenOptions?.useWebview, isFalse);
    expect(
      seenOptions?.landingPageHtml,
      contains('Close this tab and return to the app.'),
    );
    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.authenticated);
    expect(state.username, 'octocat');
    expect(calls['/auth/native/exchange'], 1);
  });

  test('oauth error param surfaces the provider message', () async {
    final store = FakeAuthStore();
    final container = makeAuthContainer(
      store,
      fakeSessionDio({}),
      oauthBrowser: ({
        required String url,
        required String callbackUrlScheme,
        FlutterWebAuth2Options? options,
      }) async => 'boltmesh://auth/callback?error=Account%20is%20suspended',
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.error, 'Account is suspended');
    expect(await store.apiToken(), isNull);
  });

  test('oauth callback without code reads as cancelled', () async {
    final store = FakeAuthStore();
    final container = makeAuthContainer(
      store,
      fakeSessionDio({}),
      oauthBrowser: ({
        required String url,
        required String callbackUrlScheme,
        FlutterWebAuth2Options? options,
      }) async => 'boltmesh://auth/callback',
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.error, 'Sign-in was cancelled.');
  });

  test('oauth browser dismissal reads as cancelled', () async {
    final store = FakeAuthStore();
    final container = makeAuthContainer(
      store,
      fakeSessionDio({}),
      oauthBrowser: ({
        required String url,
        required String callbackUrlScheme,
        FlutterWebAuth2Options? options,
      }) => throw PlatformException(code: 'CANCELED'),
    );
    await settleRestore(container);

    await container.read(authProvider.notifier).signInWithProvider('google');

    final state = container.read(authProvider).requireValue;
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.error, 'Sign-in was cancelled.');
  });

  test('loginMessage maps kinds', () {
    DioException httpError(int status, String message) => DioException(
      requestOptions: RequestOptions(path: '/auth/login'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/auth/login'),
        statusCode: status,
        data: {'detail': message},
      ),
      error: ApiException(ApiErrorKind.unauthorized, message, status),
    );
    expect(loginMessage(httpError(401, 'bad')), contains('Incorrect'));
    expect(
      loginMessage(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          error: const ApiException(ApiErrorKind.unknown, 'Too fast', 429),
        ),
      ),
      contains('Too many attempts'),
    );
    expect(
      loginMessage(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        ),
      ),
      contains('No network'),
    );
  });
}
