import 'package:dio/dio.dart';

import '../../../core/dio_client.dart';
import '../../../core/env.dart';
import 'auth_models.dart';

/// Plain Dio for the session endpoints (no auth interceptor: login has no
/// token yet and refresh must not recurse into itself).
///
/// Never sends an `Origin` header: backend `require_safe_origin` lets
/// origin-less native requests pass but rejects mismatched origins with
/// 403 CSRF_ORIGIN_REJECTED. Dio on native sends none by default.
Dio buildAuthDio() {
  final dio = baseDio();

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        stampRequest(options);
        handler.next(options);
      },
      onError: (e, handler) {
        rejectMappedError(handler, e, area: 'auth');
      },
    ),
  );

  return dio;
}

/// Thin client over backend/app/auth/routers/session.py.
///
/// The refresh JWT is an HttpOnly cookie (`Path=/v1/auth`); this client
/// reads it from `Set-Cookie` and re-sends it as a `Cookie` header since
/// Flutter native has no cookie jar.
class AuthApi {
  final Dio _dio;
  const AuthApi(this._dio);

  /// `POST /auth/login` (form-urlencoded: OAuth2PasswordRequestForm).
  /// `identifier` accepts username or email. Native sessions are always
  /// persistent (`remember_me=true`): the refresh token lives in secure
  /// storage until Log Out or server-side revocation.
  Future<AuthTokens> login({
    required String identifier,
    required String password,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/auth/login',
      data: {
        'grant_type': 'password',
        'username': identifier,
        'password': password,
        'remember_me': 'true',
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return AuthTokens.fromLogin(
      r.data as Map<String, dynamic>,
      refreshToken: parseRefreshToken(r.headers['set-cookie']),
    );
  }

  /// `POST /auth/refresh-token` (no body). Rotates the session: the
  /// response carries new tokens plus a new `Set-Cookie`.
  Future<AuthTokens> refresh({
    String? refreshToken,
    String? accessToken,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/auth/refresh-token',
      options: _sessionHeaders(
        refreshToken: refreshToken,
        accessToken: accessToken,
      ),
    );
    return AuthTokens.fromLogin(
      r.data as Map<String, dynamic>,
      refreshToken: parseRefreshToken(r.headers['set-cookie']) ?? refreshToken,
    );
  }

  /// `POST /auth/logout` (204, idempotent — always succeeds at HTTP layer).
  Future<void> logout({String? refreshToken, String? accessToken}) async {
    await _dio.post<void>(
      '/auth/logout',
      options: _sessionHeaders(
        refreshToken: refreshToken,
        accessToken: accessToken,
      ),
    );
  }

  /// Cookie + Bearer headers shared by the session endpoints that carry an
  /// existing session (the refresh JWT is an HttpOnly cookie Flutter native
  /// has no jar for, so it is re-sent explicitly).
  static Options _sessionHeaders({String? refreshToken, String? accessToken}) =>
      Options(
        headers: {
          if (refreshToken != null && refreshToken.isNotEmpty)
            'Cookie': cookieHeader(refreshToken),
          if (accessToken != null && accessToken.isNotEmpty)
            'Authorization': 'Bearer $accessToken',
        },
      );

  /// Landing page served by the desktop loopback listener after the
  /// provider redirects back. Browsers block script-closing tabs they did
  /// not open themselves, so the copy tells the user to close the tab and
  /// return to the app instead of promising an auto-close.
  static const desktopLandingPageHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Signed in to BoltMesh</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body { margin: 0; padding: 0; }
    main {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;
    }
    #text { padding: 2em; text-align: center; font-size: 1.5rem; }
  </style>
</head>
<body>
  <main>
    <div id="text">Signed in to BoltMesh. Close this tab and return to the app.</div>
  </main>
</body>
</html>
''';

  /// Authorize URL opening the provider consent page in the system browser
  /// (`GET /auth/{provider}?platform=native`). Native sessions are always
  /// persistent; the result lands on `Env.oauthCallbackScheme`, or on
  /// `nativeCallback` (desktop loopback) when given.
  ///
  /// [codeChallenge] is the app's S256 PKCE challenge, bound by the backend
  /// onto the single-use exchange code. Required: the backend rejects a
  /// native authorize without it.
  static String oauthAuthorizeUrl(
    String provider, {
    required String codeChallenge,
    String? nativeCallback,
  }) {
    final base =
        '${Env.apiBaseUrl}/auth/$provider?platform=native&remember_me=true'
        '&code_challenge=$codeChallenge&code_challenge_method=S256';
    if (nativeCallback == null) return base;
    return '$base&native_callback=${Uri.encodeQueryComponent(nativeCallback)}';
  }

  /// `POST /auth/native/exchange` (single-use `{code}` from the app callback
  /// redirect). [codeVerifier] must hash to the challenge sent to authorize,
  /// or the backend refuses to spend the code. Answers like login: `TokenOut`
  /// JSON plus a refresh `Set-Cookie`.
  Future<AuthTokens> exchangeNativeCode(
    String code, {
    required String codeVerifier,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/auth/native/exchange',
      data: {'code': code, 'code_verifier': codeVerifier},
    );
    return AuthTokens.fromLogin(
      r.data as Map<String, dynamic>,
      refreshToken: parseRefreshToken(r.headers['set-cookie']),
    );
  }

  /// `GET /users` (current profile) resolving the display name after an
  /// OAuth exchange, which carries no username of its own. Null when the
  /// payload has no usable username.
  Future<String?> profileUsername({required String accessToken}) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/users',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final data = r.data;
    if (data is Map<String, dynamic>) {
      final username = data['username'];
      if (username is String && username.isNotEmpty) return username;
    }
    return null;
  }

  /// First `refresh_token=...` value across `Set-Cookie` headers, or null
  /// when the server set no refresh cookie.
  static String? parseRefreshToken(List<String>? setCookieHeaders) {
    if (setCookieHeaders == null) return null;
    for (final header in setCookieHeaders) {
      for (final part in header.split(';')) {
        final eq = part.indexOf('=');
        if (eq < 0) continue;
        if (part.substring(0, eq).trim() == 'refresh_token') {
          final value = part.substring(eq + 1).trim();
          if (value.isNotEmpty) return value;
        }
      }
    }
    return null;
  }

  static String cookieHeader(String refreshToken) =>
      'refresh_token=$refreshToken';
}
