// Human-readable mapping of backend HTTP errors shared by the VPN and auth
// flows. Status codes from backend/app/vpn/README.md + routers/devices.py.
enum ApiErrorKind {
  unauthorized,
  forbiddenNoSubscription,
  forbidden,
  deviceLimit,
  notFound,
  noActivePeer,
  alreadyConnected,
  keyInUse,
  idempotencyConflict,
  noCapacity,
  validation,
  network,
  tls,
  rateLimited,
  unknown,
}

class ApiException implements Exception {
  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  final String? code;

  /// Server-advised wait parsed from a `Retry-After` header (429/503), or
  /// null when the header was absent/unparseable. Callers use it to arm a
  /// client-side cooldown that honors the backend window instead of hammering
  /// it with more rejected requests.
  final Duration? retryAfter;

  const ApiException(
    this.kind,
    this.message, [
    this.statusCode,
    this.code,
    this.retryAfter,
  ]);

  @override
  String toString() => message;
}

/// True when a 404 means "device exists but has no bound peer" (expected
/// after `disconnect`), not "device missing". Prefers the machine-readable
/// backend `code` (`DEVICE_NO_ACTIVE_PEER`); falls back to the detail text
/// for older backends that only send `DEVICE_NOT_FOUND`.
bool isPeerless404(String? code, String lowerDetail) =>
    code == 'DEVICE_NO_ACTIVE_PEER' || lowerDetail.contains('no active peer');

/// Generic copy for gateway/proxy outages. Reverse proxies in front of the
/// backend answer 502/504 (and sometimes 500) with an HTML error page, which
/// must never reach the UI verbatim.
const backendUnreachableMessage =
    'Backend unreachable. Check your connection and retry.';

/// True when a backend/proxy error body looks like an HTML error page
/// (e.g. a proxy's `Bad Gateway` page) rather than a JSON `detail` string.
bool looksLikeHtmlBody(String body) {
  final lower = body.trimLeft().toLowerCase();
  return lower.startsWith('<') ||
      lower.contains('<html') ||
      lower.contains('<!doctype html') ||
      lower.contains('<title');
}

/// Single source of truth for backend error mapping: returns the
/// machine-readable [ApiErrorKind] paired with its user-facing message.
///
/// Unknown/foreign device IDs both surface as 404 (no ownership oracle),
/// so callers must treat 404 as "reprovision" (see binding_helpers.py).
/// HTML bodies and 500/502/504 collapse to [backendUnreachableMessage] so a
/// proxy outage never renders raw markup; the HTML override touches only the
/// message, never the kind.
({ApiErrorKind kind, String message}) classifyApiError(
  int? status,
  dynamic detail, [
  String? code,
]) {
  final d = detail?.toString() ?? '';
  final lower = d.toLowerCase();
  ({ApiErrorKind kind, String message}) result;
  switch (status) {
    case 401:
      result = (
        kind: ApiErrorKind.unauthorized,
        message: 'Session expired. Please log in again.',
      );
    case 403:
      if (code == 'DEVICE_LIMIT_EXCEEDED' || lower.contains('device limit')) {
        result = (
          kind: ApiErrorKind.deviceLimit,
          message: 'Device limit reached for your plan. Remove a device to continue.',
        );
      } else if (code == 'ACCOUNT_INACTIVE' ||
          lower.contains('account is inactive')) {
        result = (
          kind: ApiErrorKind.forbidden,
          message:
              'This account is inactive. Contact support to restore access.',
        );
      } else if (code == 'DEVICE_INACTIVE' ||
          lower.contains('device is inactive')) {
        result = (
          kind: ApiErrorKind.forbidden,
          message: 'This device is inactive and cannot connect.',
        );
      } else if (code == 'SUBSCRIPTION_REQUIRED' ||
          lower.contains('subscription')) {
        result = (
          kind: ApiErrorKind.forbiddenNoSubscription,
          message: 'No active subscription. Renew to connect.',
        );
      } else {
        result = (
          kind: ApiErrorKind.forbidden,
          message: d.isEmpty ? 'Access denied.' : d,
        );
      }
    case 404:
      if (isPeerless404(code, lower)) {
        result = (
          kind: ApiErrorKind.noActivePeer,
          message: 'No active connection. Binding a fresh peer…',
        );
      } else {
        result = (
          kind: ApiErrorKind.notFound,
          message: 'Device or server not found. Reprovision this device.',
        );
      }
    case 409:
      // Key reuse first and by code: the backend's PUBLIC_KEY_IN_USE detail
      // ("This WireGuard public key is already registered to another
      // device.") also contains "already", so a text-only `already` check
      // would shadow it and kill the fresh-key retry. Idempotency next: its
      // payloads contain "already" too.
      if (code == 'PUBLIC_KEY_IN_USE' ||
          lower.contains('public key') ||
          lower.contains('in use')) {
        result = (
          kind: ApiErrorKind.keyInUse,
          message: 'Key already in use. Generating a fresh key…',
        );
      } else if ((code != null && code.contains('IDEMPOT')) ||
          lower.contains('idempot')) {
        result = (
          kind: ApiErrorKind.idempotencyConflict,
          message: 'Provision already in flight. Retrying with the same key.',
        );
      } else if (lower.contains('already') || lower.contains('connected')) {
        result = (
          kind: ApiErrorKind.alreadyConnected,
          message: 'Already connected. Loading existing config.',
        );
      } else {
        result = (kind: ApiErrorKind.unknown, message: 'Conflict ($d).');
      }
    case 422:
      result = (kind: ApiErrorKind.validation, message: 'Invalid request: $d');
    // Rate limiting is an app-level, retryable rejection: a dedicated kind so
    // the connection state machine can arm a cooldown off the `Retry-After`
    // header (see `ApiException.retryAfter`) instead of treating it as a
    // generic failure and retrying immediately.
    case 429:
      result = (
        kind: ApiErrorKind.rateLimited,
        message: d.isEmpty ? 'Rate limit reached. Please retry shortly.' : d,
      );
    // 502/504 are gateway/proxy failures: the backend itself was never
    // reached, so they stay transport (proxy HTML is sanitized below).
    // 500 is an app-level answer that proves the backend IS reachable and
    // must not be treated as transport (see `isTransportFailure`), so it
    // falls through to `default`/`unknown` and keeps the backend detail.
    case 502:
    case 504:
      result = (kind: ApiErrorKind.network, message: backendUnreachableMessage);
    case 503:
      result = (
        kind: ApiErrorKind.noCapacity,
        message: 'No capacity right now ($d). Try another region.',
      );
    default:
      result = (
        kind: ApiErrorKind.unknown,
        message: d.isEmpty ? 'Request failed (status $status).' : d,
      );
  }
  return looksLikeHtmlBody(d)
      ? (kind: result.kind, message: backendUnreachableMessage)
      : result;
}

/// User-facing message for a backend error (see [classifyApiError]).
String friendlyMessage(int? status, dynamic detail, [String? code]) =>
    classifyApiError(status, detail, code).message;

/// Machine-readable kind for a backend error (see [classifyApiError]).
ApiErrorKind kindFor(int? status, dynamic detail, [String? code]) =>
    classifyApiError(status, detail, code).kind;
