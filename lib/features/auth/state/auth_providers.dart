import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../../core/dio_client.dart';
import '../../../core/env.dart';
import '../../../core/log.dart';
import '../data/auth_api.dart';
import '../data/auth_models.dart';
import '../data/native_loopback_stub.dart'
    if (dart.library.io) '../data/native_loopback_io.dart'
    as native_loopback;
import '../data/pkce.dart';
import '../data/session_store.dart';
import 'auth_state.dart';
import 'login_messages.dart';

export 'auth_state.dart';
export 'login_messages.dart';

part 'auth_session.dart';

final authApiProvider = Provider((_) => AuthApi(buildAuthDio()));

/// System-browser launcher for the OAuth flow. Provider (not a direct
/// `FlutterWebAuth2` call) so tests can substitute a fake callback URL.
typedef OAuthAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options? options,
});

final oauthAuthenticateProvider = Provider<OAuthAuthenticate>(
  (_) =>
      ({
        required String url,
        required String callbackUrlScheme,
        FlutterWebAuth2Options? options,
      }) => FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: callbackUrlScheme,
        options: options ?? const FlutterWebAuth2Options(),
      ),
);

/// Desktop loopback return address for OAuth (`http://127.0.0.1:{port}/callback`),
/// or null on mobile/web where the `boltmesh://` custom scheme is used.
/// The port is ephemeral per attempt (bind 0, release, advertise).
final nativeLoopbackProvider = FutureProvider<String?>((_) async {
  if (kIsWeb) return null;
  final platform = defaultTargetPlatform;
  if (platform != TargetPlatform.windows && platform != TargetPlatform.linux) {
    return null;
  }
  final port = await native_loopback.findFreeLoopbackPort();
  return 'http://127.0.0.1:$port/callback';
});

/// Owns the user session: login, proactive access-token refresh, logout.
///
/// The access JWT lives ~15 min; the controller schedules a refresh at
/// `expiresAt` (stored alongside the tokens) and the VPN Dio also triggers
/// [refreshForRetry] once per 401. Refresh is single-flight: concurrent
/// callers share one POST, since rotation is single-use and a double POST
/// revokes all sessions server-side.
///
/// Startup restore runs in [build] itself (async): while the provider is
/// loading the auth gate shows a spinner, so provisioning and discovery
/// (mounted only under `authenticated`) can never race the restore.
///
/// One-way dependency only: VPN providers read this controller, never the
/// reverse (so logout callers reset the tunnel controller themselves).
class AuthController extends AsyncNotifier<AuthState> {
  SessionStore get _store => ref.read(sessionStoreProvider);
  AuthApi get _api => ref.read(authApiProvider);

  Timer? _timer;
  Future<bool>? _flight;

  /// Bumped by [_signOut]. A refresh captures it before awaiting the network
  /// and drops its result (rotated tokens and state flip) when it changed
  /// meanwhile, so a refresh already in flight when the user logs out can
  /// never resurrect the session by re-persisting tokens after the wipe.
  int _authGen = 0;

  /// Read/write view of [AsyncNotifier.state] for the same-library part
  /// (`auth_session.dart`). UI and tests must keep using [authProvider].
  AsyncValue<AuthState> get snap => state;
  set snap(AsyncValue<AuthState> s) => state = s;

  /// Same-library [Ref] view for `auth_session.dart` (same reason as [snap]).
  Ref get scope => ref;

  @override
  Future<AuthState> build() async {
    ref.onDispose(() => _timer?.cancel());
    return _restore();
  }

  /// Test seam: cancels the scheduled proactive refresh.
  @visibleForTesting
  void debugCancelTimer() => _timer?.cancel();
  Future<void> login({
    required String identifier,
    required String password,
  }) async {
    final current = state.value ?? const AuthState();
    if (current.working) return;
    state = AsyncData(current.copyWith(working: true, error: null));
    try {
      final id = identifier.trim();
      // Native sessions are always persistent: the refresh token lives in
      // secure storage until Log Out or server-side revocation.
      final tokens = await _api.login(identifier: id, password: password);
      // Resolve the canonical display name: the identifier may be an email
      // or differently-cased username. Fall back to the typed identifier so
      // a profile miss never fails the login.
      String? username;
      try {
        username = await _api.profileUsername(accessToken: tokens.accessToken);
      } catch (e) {
        AppLog.error('auth login profile lookup failed', e);
      }
      username ??= id;
      await _store.setAuth(
        accessToken: tokens.accessToken,
        expiresAt: tokens.expiresAt,
        refreshToken: tokens.refreshToken,
        username: username,
      );
      if (!ref.mounted) return;
      _schedule(tokens.expiresAt);
      AppLog.info('auth login ok user=$username');
      state = AsyncData(
        AuthState(status: AuthStatus.authenticated, username: username),
      );
    } catch (e) {
      AppLog.error('auth login failed', asVpnError(e)?.message ?? e);
      if (!ref.mounted) return;
      final failed = state.value ?? const AuthState();
      state = AsyncData(
        failed.copyWith(working: false, error: loginMessage(e)),
      );
    }
  }

  /// OAuth sign-in: provider consent in the system browser, single-use code
  /// back on the app callback, exchanged for session tokens over direct
  /// HTTPS. Mobile uses the `boltmesh://` custom scheme; desktop
  /// (Windows/Linux) uses an ephemeral loopback listener
  /// (`http://127.0.0.1:{port}/callback`) in the external browser. The display
  /// name is resolved from the profile since the code carries no username.
  Future<void> signInWithProvider(String provider) async {
    final current = state.value ?? const AuthState();
    if (current.working) return;
    state = AsyncData(current.copyWith(working: true, error: null));
    try {
      // App-bound PKCE: the verifier stays in memory, its challenge is bound
      // to the single-use code, so another app that hijacks the callback
      // scheme cannot redeem a stolen code. See `data/pkce.dart`.
      final pkce = generatePkcePair();
      final oauthAuthenticate = ref.read(oauthAuthenticateProvider);

      Future<String> authenticate() async {
        // Allocate a fresh loopback port for every attempt. The provider is
        // intentionally cached by Riverpod, so invalidate it before reading;
        // reusing the first port makes a transient bind conflict permanent for
        // the lifetime of this provider container. The plugin binds the port
        // after this allocation, so retry once if that unavoidable hand-off
        // loses a race with another local process.
        for (var attempt = 0; attempt < 2; attempt++) {
          ref.invalidate(nativeLoopbackProvider);
          final loopback = await ref.read(nativeLoopbackProvider.future);
          final url = AuthApi.oauthAuthorizeUrl(
            provider,
            nativeCallback: loopback,
            codeChallenge: pkce.challenge,
          );
          AppLog.info('auth oauth start provider=$provider url=$url');
          try {
            return await oauthAuthenticate(
              url: url,
              callbackUrlScheme: loopback ?? Env.oauthCallbackScheme,
              options: loopback == null
                  ? null
                  : const FlutterWebAuth2Options(
                      useWebview: false,
                      landingPageHtml: AuthApi.desktopLandingPageHtml,
                    ),
            );
          } catch (e) {
            if (loopback != null &&
                attempt == 0 &&
                native_loopback.isLoopbackBindFailure(e)) {
              AppLog.info('auth oauth loopback port busy; retrying');
              continue;
            }
            rethrow;
          }
        }
        throw StateError('Unable to allocate an OAuth loopback port.');
      }

      final callback = await authenticate();
      final params = Uri.parse(callback).queryParameters;
      // The callback is attacker-reachable on Android (any app may register
      // the scheme): bound and strip the provider-supplied error before it is
      // ever rendered.
      final failure = sanitizeOauthError(params['error']);
      if (failure != null) {
        if (!ref.mounted) return;
        final failed = state.value ?? const AuthState();
        state = AsyncData(failed.copyWith(working: false, error: failure));
        return;
      }
      final code = params['code'];
      if (code == null || code.isEmpty) {
        // No code and no error: the flow never completed (dismissed
        // before the provider redirected back).
        if (!ref.mounted) return;
        final failed = state.value ?? const AuthState();
        state = AsyncData(
          failed.copyWith(working: false, error: 'Sign-in was cancelled.'),
        );
        return;
      }
      final tokens = await _api.exchangeNativeCode(
        code,
        codeVerifier: pkce.verifier,
      );
      String? username;
      try {
        username = await _api.profileUsername(accessToken: tokens.accessToken);
      } catch (e) {
        // Display name only: a profile miss must not fail the login.
        AppLog.error('auth oauth profile lookup failed', e);
      }
      await _store.setAuth(
        accessToken: tokens.accessToken,
        expiresAt: tokens.expiresAt,
        refreshToken: tokens.refreshToken,
        username: username,
      );
      if (!ref.mounted) return;
      _schedule(tokens.expiresAt);
      AppLog.info('auth oauth login ok provider=$provider');
      state = AsyncData(
        AuthState(status: AuthStatus.authenticated, username: username),
      );
    } on PlatformException catch (e) {
      // The plugin uses CANCELED for an actual browser dismissal. Other
      // PlatformExceptions (missing browser, timeout, invalid platform
      // configuration) are failures, not user cancellation.
      if (e.code.toUpperCase() == 'CANCELED') {
        AppLog.info('auth oauth cancelled');
        if (!ref.mounted) return;
        final failed = state.value ?? const AuthState();
        state = AsyncData(
          failed.copyWith(working: false, error: 'Sign-in was cancelled.'),
        );
        return;
      }
      AppLog.error('auth oauth platform failure', e);
      if (!ref.mounted) return;
      final failed = state.value ?? const AuthState();
      state = AsyncData(
        failed.copyWith(working: false, error: loginMessage(e)),
      );
    } catch (e) {
      AppLog.error('auth oauth login failed', asVpnError(e)?.message ?? e);
      if (!ref.mounted) return;
      final failed = state.value ?? const AuthState();
      state = AsyncData(
        failed.copyWith(working: false, error: loginMessage(e)),
      );
    }
  }

  /// Single-flight session renewal. True when the store now holds a fresh
  /// access token; false leaves existing tokens untouched except on
  /// explicit revocation (401/403), which signs out.
  Future<bool> refreshForRetry() {
    final flight = _flight;
    if (flight != null) return flight;
    final fut = _doRefresh();
    _flight = fut;
    unawaited(
      fut.whenComplete(() {
        if (identical(_flight, fut)) _flight = null;
      }),
    );
    return fut;
  }

  /// Resume catch-up: refreshes the session only when the stored access
  /// token is expired (the proactive [Timer] may have missed its slot while
  /// the app was suspended). No-op when unauthenticated or still valid, so
  /// rapid pause/resume cycles never spam `POST /auth/refresh-token`.
  /// Returns true when a refresh was attempted and succeeded.
  Future<bool> refreshIfExpired({DateTime? now}) async {
    if (snap.value?.status != AuthStatus.authenticated) return false;
    DateTime? expiry;
    try {
      expiry = await _store.accessExpiry();
    } catch (e) {
      AppLog.error('auth resume expiry read failed', e);
      return false;
    }
    if (expiry == null) return false;
    if ((now ?? DateTime.now()).isBefore(expiry)) return false;
    AppLog.info('auth resume refresh (access expired while suspended)');
    return refreshForRetry();
  }

  /// Best-effort server revocation; local state always clears so logout
  /// works offline too. Callers reset the tunnel controller separately.
  Future<void> logout() async {
    final current = state.value ?? const AuthState();
    if (current.working) return;
    state = AsyncData(current.copyWith(working: true, error: null));
    try {
      final refresh = await _store.refreshToken().catchError((_) => null);
      final access = await _store.apiToken().catchError((_) => null);
      try {
        await _api.logout(refreshToken: refresh, accessToken: access);
      } catch (e) {
        AppLog.error('auth logout api failed', e);
      }
    } finally {
      await _signOut();
    }
  }
}

final authProvider = AsyncNotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
