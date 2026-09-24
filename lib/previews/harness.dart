import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../features/auth/data/session_store.dart';
import '../features/auth/state/auth_providers.dart';
import '../features/vpn/data/backend_health.dart';
import '../features/vpn/data/device_store.dart';
import '../features/vpn/data/models.dart';
import '../features/vpn/state/vpn_providers.dart';
import '../l10n/gen/app_localizations.dart';

/// Fakes + shell wrapper shared by the previewer entries in `lib/previews/`.
///
/// Each preview wraps the screen in a [ProviderScope] with fake overrides
/// (same pattern as `test/widget_test.dart`), so previews never touch the
/// network or native plugins — the previewer runs on Flutter Web, where
/// `wireguard_flutter_plus` / `flutter_secure_storage` are unavailable.
/// `.widget_preview/` stays gitignored; only `lib/previews.dart` and
/// `lib/previews/` are checked in.
///
/// These doubles are public (unlike `test/widget_test.dart`'s) because a
/// preview cannot import from `test/` and each preview file needs them.
Widget previewShell({
  required ConnState connState,
  bool authenticated = true,
  List<Region>? regions,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      connectionProvider.overrideWith(
        () => PreviewConnectionController(connState),
      ),
      deviceStoreProvider.overrideWithValue(PreviewDeviceStore()),
      sessionStoreProvider.overrideWithValue(const PreviewSessionStore()),
      authProvider.overrideWith(
        authenticated
            ? PreviewAuthedController.new
            : PreviewUnauthedController.new,
      ),
      // The Home watches the backend-health poll; pin it so previews stay
      // offline-free (the previewer runs on web without native plugins).
      backendHealthProvider.overrideWith(
        (ref) => Stream.value(BackendHealth.reachable),
      ),
      if (regions != null)
        regionsProvider.overrideWithValue(AsyncValue.data(regions)),
    ],
    child: MaterialApp(
      // Screens read l10n with a non-null assertion (`AppLocalizations.of`);
      // without the delegate every preview would throw on build.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: boltMeshTheme,
      darkTheme: boltMeshDarkTheme,
      home: child,
    ),
  );
}

/// Connection controller stub: renders the given state, all actions no-ops.
class PreviewConnectionController extends ConnectionController {
  PreviewConnectionController(this._state);

  final ConnState _state;

  @override
  ConnState build() => _state;

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

  @override
  Future<void> rotateKeys({bool auto = false}) async {}

  // Settings actions must not run the real teardown/release graph (it would
  // touch secure storage, unavailable on the web previewer).
  @override
  Future<void> releaseDevice() async {}

  @override
  Future<void> forgetDevice() async {}

  @override
  Future<bool> setAllowLocal(bool value) async => true;

  @override
  void reset() {}
}

/// Authenticated [AuthController] stub for previews.
class PreviewAuthedController extends AuthController {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, username: 'tester');

  @override
  Future<void> login({
    required String identifier,
    required String password,
  }) async {}

  @override
  Future<void> logout() async {}
}

/// Unauthenticated [AuthController] stub for previews.
class PreviewUnauthedController extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> login({
    required String identifier,
    required String password,
  }) async {}

  @override
  Future<void> logout() async {}
}

/// In-memory session store: no tokens, so the previews stay logged out of
/// the real secure-storage plugin (unavailable on the web previewer).
class PreviewSessionStore extends SessionStore {
  const PreviewSessionStore();

  @override
  Future<String?> apiToken() async => null;

  @override
  Future<String?> refreshToken() async => null;

  @override
  Future<DateTime?> accessExpiry() async => null;

  @override
  Future<String?> authUsername() async => 'tester';
}

/// In-memory device store: a readable name, no secure-storage writes.
class PreviewDeviceStore extends DeviceStore {
  PreviewDeviceStore();

  @override
  Future<String?> deviceName() async => 'Preview Device';

  // The Settings LAN tile reads this through `allowLocalProvider`; without the
  // override it would hit the real secure-storage plugin (unavailable on the
  // web previewer).
  @override
  Future<bool> allowLocal() async => true;

  @override
  Future<void> setAllowLocal(bool v) async {}

  // In-memory no-ops so preview interactions (Save name, Forget device)
  // never reach the real secure-storage plugin, which is unavailable on
  // the web previewer.
  @override
  Future<void> setDeviceName(String v) async {}

  @override
  Future<void> clearDevice() async {}
}
