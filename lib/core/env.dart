// API base URL + tunnel constants.
//
// Backend mounts user routes under {API_V1_PREFIX} = `/v1`
// (see backend/app/core/config.py, backend/app/vpn/router.py).
//
// The default is the local `podman-compose` stack from the `infra` repo, so a
// fresh clone runs against localhost with no configuration. Any other API —
// the real backend included — comes from `API_BASE_URL`, supplied either as
// `--dart-define=API_BASE_URL=...` or through `.env` via
// `flutter run --dart-define-from-file=.env`. Release builds still refuse a
// cleartext `http://` URL (see `dio_client.dart`); the production URL is
// pinned per job in `distribute_options.yaml`, which is why CI needs no
// `.env` of its own.

/// Trims whitespace and every trailing slash, so path joins never produce
/// `//segment` (and `healthUrl` can drop a `/v1` suffix cleanly).
String stripTrailingSlashes(String url) {
  var v = url.trim();
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

/// True when [url] is a well-formed absolute `http`/`https` URL with a host.
///
/// The website URL comes from a compile-time define, so it is only as trusted
/// as the build that set it — but it is launched into an external browser, and
/// a typo or a stray define should never hand the platform some other scheme
/// (`file:`, an app's custom scheme). Anything that is not plainly a web URL
/// is treated as "not configured" and the link is hidden instead.
bool isLaunchableWebUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.isAbsolute) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

class Env {
  static const _rawApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/v1',
  );

  static const _rawWebsiteUrl = String.fromEnvironment('WEBSITE_URL');

  /// Normalized base URL without a trailing slash, so path joins in
  /// [VpnApi] never produce `//vpn-regions`.
  static String get apiBaseUrl => stripTrailingSlashes(_rawApiBaseUrl);

  /// Public site where accounts are created, shown on the login screen. Set
  /// it with `--dart-define=WEBSITE_URL=...` or through `.env` via
  /// `--dart-define-from-file=.env`; release jobs pin it in
  /// `distribute_options.yaml`.
  ///
  /// Empty (the default, and every plain `flutter run` that reads no `.env`)
  /// means "not configured": the login screen then shows no account-creation
  /// affordance at all rather than a dead link.
  static String get websiteUrl {
    final value = stripTrailingSlashes(_rawWebsiteUrl);
    return isLaunchableWebUrl(value) ? value : '';
  }

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
