import 'dart:io';
import 'dart:typed_data';

import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/auth/data/auth_api.dart';
import 'package:boltmesh/features/auth/data/auth_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// The `if (... != null)` guard below intentionally stays verbose: a
// null-aware entry (`?key: value`) would still send an explicit null header.
// ignore_for_file: use_null_aware_elements

/// Dio that captures the outgoing request and answers with canned JSON plus
/// optional `Set-Cookie` headers, so no HTTP client is needed.
Dio fakeAuthDio({
  required Map<String, dynamic> Function(RequestOptions options) respond,
  List<String>? setCookie,
  int statusCode = 200,
  List<RequestOptions>? seen,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        seen?.add(options);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: statusCode,
            data: respond(options),
            headers: Headers.fromMap({
              if (setCookie != null) 'set-cookie': setCookie,
            }),
          ),
        );
      },
    ),
  );
  return dio;
}

Map<String, dynamic> tokenJson() => {
  'access_token': 'access-1',
  'token_type': 'bearer',
  'expires_in': 900,
  'refresh_expires_in': 604800,
};

void main() {
  test('login posts form fields and parses tokens + refresh cookie', () async {
    final seen = <RequestOptions>[];
    final api = AuthApi(
      fakeAuthDio(
        respond: (_) => tokenJson(),
        setCookie: const [
          'refresh_token=r1; Path=/v1/auth; HttpOnly; SameSite=Lax',
        ],
        seen: seen,
      ),
    );
    final tokens = await api.login(
      identifier: 'john@example.com',
      password: 'Secret123',
    );
    expect(tokens.accessToken, 'access-1');
    expect(tokens.refreshToken, 'r1');
    expect(tokens.refreshExpiresIn, 604800);
    expect(
      tokens.expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 13))),
      isTrue,
    );
    final req = seen.single;
    expect(req.path, '/auth/login');
    expect(req.contentType, Headers.formUrlEncodedContentType);
    final body = req.data as Map;
    expect(body['grant_type'], 'password');
    expect(body['username'], 'john@example.com');
    expect(body['password'], 'Secret123');
    expect(body['remember_me'], 'true');
  });

  test('login without refresh cookie keeps null refresh token', () async {
    final api = AuthApi(fakeAuthDio(respond: (_) => tokenJson()));
    final tokens = await api.login(identifier: 'u', password: 'p');
    expect(tokens.refreshToken, isNull);
  });

  test('fromLogin throws without access token', () {
    expect(() => AuthTokens.fromLogin({}), throwsFormatException);
  });

  test('oauthAuthorizeUrl carries the S256 PKCE challenge', () {
    final url = AuthApi.oauthAuthorizeUrl(
      'google',
      codeChallenge: 'CHALLENGE43',
    );
    expect(
      url,
      endsWith(
        '/auth/google?platform=native&remember_me=true'
        '&code_challenge=CHALLENGE43&code_challenge_method=S256',
      ),
    );
  });

  test('oauthAuthorizeUrl appends the loopback callback when given', () {
    final url = AuthApi.oauthAuthorizeUrl(
      'github',
      codeChallenge: 'c',
      nativeCallback: 'http://127.0.0.1:1234/callback',
    );
    expect(
      url,
      contains('native_callback=http%3A%2F%2F127.0.0.1%3A1234%2Fcallback'),
    );
  });

  test('exchangeNativeCode posts the code and its verifier', () async {
    final seen = <RequestOptions>[];
    final api = AuthApi(
      fakeAuthDio(
        respond: (_) => tokenJson(),
        setCookie: const ['refresh_token=r9; Path=/v1/auth; HttpOnly'],
        seen: seen,
      ),
    );
    final tokens = await api.exchangeNativeCode(
      'code-abc',
      codeVerifier: 'verifier-xyz',
    );
    expect(tokens.accessToken, 'access-1');
    expect(tokens.refreshToken, 'r9');
    final req = seen.single;
    expect(req.path, '/auth/native/exchange');
    final body = req.data as Map;
    expect(body['code'], 'code-abc');
    expect(body['code_verifier'], 'verifier-xyz');
  });

  test('profileUsername resolves the display name', () async {
    final seen = <RequestOptions>[];
    final api = AuthApi(
      fakeAuthDio(respond: (_) => const {'username': 'octocat'}, seen: seen),
    );
    expect(await api.profileUsername(accessToken: 'a1'), 'octocat');
    expect(seen.single.headers['Authorization'], 'Bearer a1');
  });

  test('profileUsername is null without a usable username', () async {
    final api = AuthApi(fakeAuthDio(respond: (_) => const {'id': 'u1'}));
    expect(await api.profileUsername(accessToken: 'a1'), isNull);
  });

  test('refresh sends cookie header and picks up rotated cookie', () async {
    final seen = <RequestOptions>[];
    final api = AuthApi(
      fakeAuthDio(
        respond: (_) => tokenJson(),
        setCookie: const ['refresh_token=r2; Path=/v1/auth; HttpOnly'],
        seen: seen,
      ),
    );
    final tokens = await api.refresh(
      refreshToken: 'r1',
      accessToken: 'old-access',
    );
    expect(tokens.refreshToken, 'r2');
    final req = seen.single;
    expect(req.path, '/auth/refresh-token');
    expect(req.headers['Cookie'], 'refresh_token=r1');
    expect(req.headers['Authorization'], 'Bearer old-access');
  });

  test('refresh keeps old cookie when server sets none', () async {
    final api = AuthApi(fakeAuthDio(respond: (_) => tokenJson()));
    final tokens = await api.refresh(refreshToken: 'r1');
    expect(tokens.refreshToken, 'r1');
  });

  test('logout sends cookie + bearer to the logout path', () async {
    final seen = <RequestOptions>[];
    final api = AuthApi(
      fakeAuthDio(
        respond: (_) => <String, dynamic>{},
        seen: seen,
        statusCode: 204,
      ),
    );
    await api.logout(refreshToken: 'r1', accessToken: 'a1');
    final req = seen.single;
    expect(req.path, '/auth/logout');
    expect(req.headers['Cookie'], 'refresh_token=r1');
    expect(req.headers['Authorization'], 'Bearer a1');
  });

  test('parseRefreshToken finds value among multiple cookies', () {
    expect(
      AuthApi.parseRefreshToken(const [
        'other=x; Path=/',
        'refresh_token=abc123; Path=/v1/auth; HttpOnly',
      ]),
      'abc123',
    );
    expect(AuthApi.parseRefreshToken(const ['other=x; Path=/']), isNull);
    expect(AuthApi.parseRefreshToken(null), isNull);
    expect(AuthApi.parseRefreshToken(const []), isNull);
  });

  test(
    'transport failure keeps the user message (underlying error is logged)',
    () async {
      final dio = buildAuthDio();
      dio.httpClientAdapter = _ThrowingAdapter(
        DioException(
          requestOptions: RequestOptions(path: '/auth/native/exchange'),
          error: const SocketException('Connection reset by peer'),
        ),
      );

      try {
        await AuthApi(dio).exchangeNativeCode('abc123', codeVerifier: 'v1');
        fail('expected a throw');
      } on DioException catch (e) {
        final err = e.error;
        expect(err, isA<ApiException>());
        expect((err as ApiException).kind, ApiErrorKind.network);
        expect(err.message, contains('No network'));
      }
    },
  );

  test('desktop landing page tells the user to close the tab', () {
    expect(
      AuthApi.desktopLandingPageHtml,
      contains('Close this tab and return to the app.'),
    );
    expect(AuthApi.desktopLandingPageHtml, isNot(contains('automatically')));
  });
}

/// Adapter stub that fails every request with a canned transport error, so
/// the real interceptors run without any HTTP client.
class _ThrowingAdapter implements HttpClientAdapter {
  _ThrowingAdapter(this.error);
  final DioException error;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw error;

  @override
  void close({bool force = false}) {}
}
