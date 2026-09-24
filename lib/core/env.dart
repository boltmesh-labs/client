// API base URL + tunnel constants.
//
// Backend mounts user routes under {API_V1_PREFIX} = `/v1`
// (see backend/app/core/config.py, backend/app/vpn/router.py).
// Defaults to production; point at a local stack with
// `flutter run --dart-define=API_BASE_URL=http://localhost:8000/v1`.

/// Trims whitespace and every trailing slash, so path joins never produce
/// `//segment` (and `healthUrl` can drop a `/v1` suffix cleanly).
String stripTrailingSlashes(String url) {
  var v = url.trim();
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

class Env {
  static const _rawApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.boltmesh.mooo.com/v1',
  );

  /// Normalized base URL without a trailing slash, so path joins in
  /// [VpnApi] never produce `//vpn-regions`.
  static String get apiBaseUrl => stripTrailingSlashes(_rawApiBaseUrl);

  /// Discovery cache TTL mirrors backend `Cache-Control: private, max-age=60`
  /// on GET /vpn-regions (backend/app/vpn/routers/regions.py).
  static const regionsCacheTtl = Duration(seconds: 60);

  /// Status poll floor for GET /vpn-devices/{id}/status: the backend
  /// `status_limiter` budget is 30/min per session (clients poll through a
  /// shared egress IP when the tunnel is up), so polling must stay >= 60s.
  static const statusPollInterval = Duration(seconds: 60);

  /// Automatic key-rotation cadence, counted in status poll ticks so no
  /// extra timer is needed (24h / 60s).
  static const keyRotationPolls = 1440;

  /// Custom URL scheme the backend redirects OAuth logins to
  /// (`NATIVE_APP_CALLBACK_URL`, default `boltmesh://auth/callback`).
  ///
  /// This must stay in sync with the schemes registered in the native
  /// Android manifest and Apple platform plists. It is intentionally not a
  /// Dart define: changing only the Dart value would make the plugin wait for
  /// a callback that the operating system cannot route to this app.
  static const oauthCallbackScheme = 'boltmesh';

  /// Optional public-key (SPKI) pins: comma-separated base64-encoded SHA-256
  /// digests of the server certificate's `SubjectPublicKeyInfo` (set via
  /// `--dart-define=TLS_PIN_SPKI_SHA256=pin[,pin...]`). Every backend client
  /// rejects a chain whose SPKI matches none of the pins — on top of platform
  /// trust, never instead of it. Multiple pins allow overlapping rotation.
  ///
  /// SPKI (rather than leaf) survives certificate renewal while the key is
  /// reused. Empty (default) means platform trust only.
  static const tlsPinSpkiSha256 = String.fromEnvironment('TLS_PIN_SPKI_SHA256');

  /// True when the API points at loopback. Such setups (VSCode SSH
  /// port-forwards included) die the moment a full-tunnel goes up, because
  /// the forward's SSH underlay is routed into the tunnel — the UI warns
  /// about this instead of letting the user strand themselves.
  static bool get isLoopbackApi {
    final host = Uri.tryParse(apiBaseUrl)?.host.trim().toLowerCase() ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }
}
