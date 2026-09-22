part of 'auth_providers.dart';

/// Session restore + renewal for [AuthController] (same-library part).
/// All `snap` reads/writes go through the controller accessor (see
/// `AuthController.snap`): extensions cannot touch the protected
/// `AsyncNotifier.state` directly.
/// Retry delay after a transport failure: tokens are kept, refresh is
/// retried once before falling back to the 401 path.
const _retryAfterFailure = Duration(seconds: 30);

extension AuthSession on AuthController {
  Future<AuthState> _restore() async {
    try {
      final (access, expiry, refresh, username) = await (
        _store.apiToken(),
        _store.accessExpiry(),
        _store.refreshToken(),
        _store.authUsername(),
      ).wait;
      if (access != null &&
          access.isNotEmpty &&
          expiry != null &&
          DateTime.now().isBefore(expiry)) {
        AppLog.info('auth restore session user=${username ?? '<unknown>'}');
        final restored = AuthState(
          status: AuthStatus.authenticated,
          username: username,
        );
        _schedule(expiry);
        return restored;
      }
      if (refresh != null && refresh.isNotEmpty) {
        AppLog.info('auth restore via refresh');
        final refreshed = await _attemptRestoreRefresh(
          fallbackUsername: username,
        );
        if (refreshed != null) return refreshed;
      }
      return const AuthState();
    } catch (e) {
      // Locked keychain etc: stay usable at the login screen.
      AppLog.error('auth restore failed', e);
      return const AuthState();
    }
  }

  /// Refresh attempt used only by [_restore]: reports the resulting state
  /// via its return value instead of mutating [state] (which [build] owns
  /// until it completes). Null means "not refreshed, fall through".
  /// [fallbackUsername] is the username already read by [_restore]; it is
  /// kept when a transient re-read fails so one bad read never wipes the
  /// stored display name.
  Future<AuthState?> _attemptRestoreRefresh({String? fallbackUsername}) async {
    final gen = _authGen;
    final pair = await _readRefreshPair();
    if (pair == null) return null;
    final (refresh, access) = pair;
    if (refresh.isEmpty) {
      await _clearAuthBestEffort();
      return null;
    }
    try {
      final tokens = await _api.refresh(
        refreshToken: refresh,
        accessToken: access,
      );
      final result = await _persistRefreshed(
        tokens,
        fallbackUsername: fallbackUsername,
        gen: gen,
      );
      if (!result.persisted) return null;
      _schedule(tokens.expiresAt);
      AppLog.info('auth refresh ok');
      return AuthState(
        status: AuthStatus.authenticated,
        username: result.username,
      );
    } on DioException catch (e) {
      final kind = asVpnError(e)?.kind;
      final status = asVpnError(e)?.statusCode;
      if (status == 401 || status == 403) {
        AppLog.error('auth refresh revoked kind=$kind', e);
        await _clearAuthBestEffort();
        return const AuthState();
      }
      // Transport failure during startup restore: don't schedule a retry
      // behind the login screen. The user can retry explicitly; post-login
      // refreshes schedule via [_doRefresh] instead.
      AppLog.error('auth refresh transport failed', e);
      return null;
    } catch (e) {
      AppLog.error('auth refresh failed', e);
      return null;
    }
  }

  Future<bool> _doRefresh() async {
    // Captured before the network await: if [_signOut] bumped it meanwhile,
    // this refresh belongs to a dead session. Dropping its result here is
    // what stops a slow refresh from re-authenticating after Log Out.
    final gen = _authGen;
    final pair = await _readRefreshPair();
    if (pair == null) return false;
    final (refresh, access) = pair;
    if (refresh.isEmpty) {
      await _signOut();
      return false;
    }
    try {
      final tokens = await _api.refresh(
        refreshToken: refresh,
        accessToken: access,
      );
      final result = await _persistRefreshed(
        tokens,
        fallbackUsername: snap.value?.username,
        gen: gen,
      );
      if (!result.persisted) return false;
      if (!scope.mounted) return true;
      _schedule(tokens.expiresAt);
      AppLog.info('auth refresh ok');
      final current = snap.value;
      if (current == null || current.status != AuthStatus.authenticated) {
        snap = AsyncData(
          AuthState(
            status: AuthStatus.authenticated,
            username: result.username,
          ),
        );
      }
      return true;
    } on DioException catch (e) {
      final kind = asVpnError(e)?.kind;
      final status = asVpnError(e)?.statusCode;
      if (status == 401 || status == 403) {
        // Revoked/reused/missing refresh, or suspended account: the stored
        // session is dead server-side, sign out instead of retrying.
        AppLog.error('auth refresh revoked kind=$kind', e);
        await _signOut();
        return false;
      }
      AppLog.error('auth refresh transport failed', e);
      _scheduleIn(_retryAfterFailure);
      return false;
    } catch (e) {
      AppLog.error('auth refresh failed', e);
      return false;
    }
  }

  /// Reads the stored refresh + access token pair (refresh first). Null when
  /// storage itself fails. An empty first value means "no refresh token".
  Future<(String, String?)?> _readRefreshPair() async {
    try {
      final refresh = await _store.refreshToken() ?? '';
      final access = await _store.apiToken();
      return (refresh, access);
    } catch (e) {
      AppLog.error('auth refresh storage read failed', e);
      return null;
    }
  }

  /// Persists rotated tokens and resolves the display name, keeping
  /// [fallbackUsername] when a transient re-read fails (writing null would
  /// delete it from storage).
  ///
  /// [gen] is the caller's captured generation. When it no longer matches
  /// (a sign-out landed while this refresh was in flight) the write is
  /// skipped and `persisted` is false, so a dead refresh can never restore
  /// tokens after logout. The check is repeated after the username read so
  /// the narrow gap before [SessionStore.setAuth] is covered too.
  Future<({String? username, bool persisted})> _persistRefreshed(
    AuthTokens tokens, {
    String? fallbackUsername,
    required int gen,
  }) async {
    if (gen != _authGen) return (username: null, persisted: false);
    String? username;
    try {
      username = await _store.authUsername();
    } catch (e) {
      AppLog.error('auth refresh username read failed', e);
      username = fallbackUsername;
    }
    if (gen != _authGen) return (username: username, persisted: false);
    await _store.setAuth(
      accessToken: tokens.accessToken,
      expiresAt: tokens.expiresAt,
      refreshToken: tokens.refreshToken,
      username: username,
    );
    return (username: username, persisted: true);
  }

  /// Clears stored auth, swallowing storage failures (the session is already
  /// known dead, so a locked keychain must not block the sign-out).
  Future<void> _clearAuthBestEffort() async {
    try {
      await _store.clearAuth();
    } catch (e) {
      AppLog.error('auth clear storage failed', e);
    }
  }

  Future<void> _signOut() async {
    // Invalidate any refresh that is currently awaiting the network: it must
    // not persist rotated tokens or flip the state back to authenticated.
    _authGen++;
    _timer?.cancel();
    try {
      await _store.clearAuth();
    } catch (e) {
      AppLog.error('auth clear storage failed', e);
    }
    if (!scope.mounted) return;
    snap = const AsyncData(AuthState());
  }

  void _schedule(DateTime expiresAt) {
    _timer?.cancel();
    final delay = expiresAt.difference(DateTime.now());
    // Store the timer even for an already-expired token: a zero/negative
    // delay fires on the next event-loop turn, and keeping it in [_timer]
    // lets [_signOut]/dispose cancel it like any other scheduled refresh.
    _timer = Timer(delay.isNegative ? Duration.zero : delay, refreshForRetry);
  }

  void _scheduleIn(Duration delay) {
    if (!scope.mounted) return;
    // Never retry behind the login screen: cancel any pending timer when
    // unauthenticated (including the loading phase where value is still
    // null but the restore already fell through).
    final v = snap.value;
    if (v == null || v.status == AuthStatus.unauthenticated) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () => refreshForRetry());
  }
}
