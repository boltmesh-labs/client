import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'env.dart';
import 'errors.dart';
import 'log.dart';
import 'tls_pinning_stub.dart'
    if (dart.library.io) 'tls_pinning_io.dart'
    as tls_pinning;

/// True when a release build points at cleartext HTTP. Debug/profile keep
/// `http://localhost` for the local `podman-compose` stack.
bool isInsecureReleaseBuild(String baseUrl, {bool releaseMode = kReleaseMode}) {
  if (!releaseMode) return false;
  return Uri.tryParse(baseUrl.trim())?.scheme == 'http';
}

/// The configured SPKI pins: comma-separated in [raw], trimmed, no empties.
/// Empty (the default via [Env.tlsPinSpkiSha256]) means platform trust only.
List<String> configuredTlsPins([String raw = Env.tlsPinSpkiSha256]) => raw
    .split(',')
    .map((pin) => pin.trim())
    .where((pin) => pin.isNotEmpty)
    .toList(growable: false);

/// Installs SPKI pin validation on [dio] when pins are configured.
///
/// No-op with no pins. When pins ARE configured but the adapter cannot
/// validate certificates, including on web, this throws [StateError] rather
/// than silently leaving the client unpinned. `dart:io` stays out of this
/// library (it breaks web builds) via the conditional import of
/// `tls_pinning_io.dart`.
void configureTlsPinning(Dio dio, {List<String>? pins}) {
  final list = pins ?? configuredTlsPins();
  if (list.isEmpty) return;
  if (kIsWeb) {
    throw StateError(
      'TLS pins are configured but certificate validation is unavailable on web.',
    );
  }
  if (!tls_pinning.installSpkiPinning(dio, list)) {
    throw StateError(
      'TLS pins are configured but this Dio adapter does not support '
      'certificate validation.',
    );
  }
}

/// Stamps a request with its start time for [requestElapsed] diagnostics.
void stampRequest(RequestOptions options) {
  options.extra['requestStartedAtMs'] = DateTime.now().millisecondsSinceEpoch;
}

/// Shared Dio error mapping for the VPN and auth interceptors.
///
/// Both clients translate failures the same way: transport failures keep a
/// generic user-facing message (the OS-level detail stays in the log line),
/// HTTP failures become [ApiException] via [kindFor]/[friendlyMessage].
/// The only per-client difference is the log prefix (`api` vs `auth`).
void rejectMappedError(
  ErrorInterceptorHandler handler,
  DioException e, {
  required String area,
}) {
  final status = e.response?.statusCode;
  AppLog.error(
    '$area ${e.requestOptions.method} ${e.requestOptions.path}'
    ' -> ${status ?? e.type.name} after ${requestElapsed(e.requestOptions)}',
    status == null
        // Transport failure: keep the underlying OS-level error
        // (SocketException/HandshakeException with its errno/reason)
        // in the log. The user-facing message stays generic on
        // purpose; this detail is what makes the next "unknown"
        // diagnosable from one log line.
        ? 'underlying=${e.error} message=${e.message}'
        : e.response?.data?.toString() ?? e.message,
  );
  if (status == null) {
    return handler.reject(
      DioException(requestOptions: e.requestOptions, error: transportError(e)),
    );
  }
  final data = e.response?.data;
  final detail = data is Map && data['detail'] != null
      ? data['detail']
      : data?.toString();
  final code = data is Map && data['code'] is String
      ? data['code'] as String
      : null;
  return handler.reject(
    DioException(
      requestOptions: e.requestOptions,
      response: e.response,
      error: ApiException(
        kindFor(status, detail, code),
        friendlyMessage(status, detail, code),
        status,
        code,
        parseRetryAfterHeader(e.response?.headers.value('retry-after')),
      ),
    ),
  );
}

/// Parses a `Retry-After` header value into a non-negative [Duration].
///
/// Accepts both forms the header allows: delta-seconds (`"60"`) and an
/// HTTP-date (`"Wed, 21 Oct 2015 07:28:00 GMT"`). Returns null when absent or
/// unparseable. Kept dependency-free (no `dart:io` `HttpDate`, which web
/// builds cannot import) and works on every platform; the backend currently
/// always sends delta-seconds.
Duration? parseRetryAfterHeader(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }
  final date = _parseHttpDate(trimmed);
  if (date == null) return null;
  final delta = date.difference(DateTime.now().toUtc());
  return delta.isNegative ? Duration.zero : delta;
}

const _httpDateMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses the HTTP-date form of `Retry-After` into UTC.
///
/// `DateTime.tryParse` only understands ISO-8601, so this covers the three
/// historical HTTP-date formats: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`),
/// RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime
/// (`Sun Nov  6 08:49:37 1994`). Returns null when none match.
DateTime? _parseHttpDate(String value) {
  final fixdate = RegExp(
    r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value);
  final rfc850 = fixdate == null
      ? RegExp(r'^\w+, (\d{2})-(\w{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$')
            .firstMatch(value)
      : null;
  if (fixdate != null || rfc850 != null) {
    final match = fixdate ?? rfc850!;
    final month = _httpDateMonths[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    var year = int.parse(match.group(3)!);
    if (rfc850 != null) {
      // Two-digit year (RFC 850): 00-69 -> 2000s, 70-99 -> 1900s.
      year += year < 70 ? 2000 : 1900;
    }
    return _validatedHttpDate(
      year,
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
  final asctime = RegExp(
    r'^\w{3} (\w{3}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
  ).firstMatch(value);
  if (asctime == null) return null;
  final month = _httpDateMonths[asctime.group(1)!.toLowerCase()];
  if (month == null) return null;
  return _validatedHttpDate(
    int.parse(asctime.group(6)!),
    month,
    int.parse(asctime.group(2)!),
    int.parse(asctime.group(3)!),
    int.parse(asctime.group(4)!),
    int.parse(asctime.group(5)!),
  );
}

DateTime? _validatedHttpDate(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  int second,
) {
  final date = DateTime.utc(year, month, day, hour, minute, second);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      date.hour != hour ||
      date.minute != minute ||
      date.second != second) {
    return null;
  }
  return date;
}

/// Elapsed wall time for a request carrying the `requestStartedAtMs` extra
/// stamp (`'n/a'` when unstamped). Log-only diagnostic, never user-facing.
String requestElapsed(RequestOptions options) {
  final startedAt = options.extra['requestStartedAtMs'];
  if (startedAt is! int) return 'n/a';
  return '${DateTime.now().millisecondsSinceEpoch - startedAt}ms';
}

/// Shared Dio for every backend call: same base URL, timeouts, and JSON
/// content type. [buildDio] (VPN session) and `buildAuthDio` (session
/// endpoints) layer their interceptors and auth handling on top.
///
/// Refuses a cleartext `http://` base URL in release builds here, so both
/// clients (auth included) fail fast instead of sending credentials or
/// tokens in the clear.
Dio baseDio() {
  if (isInsecureReleaseBuild(Env.apiBaseUrl)) {
    throw StateError('API_BASE_URL must use https:// in release builds.');
  }
  final dio = Dio(
    BaseOptions(
      baseUrl: Env.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'Content-Type': 'application/json'},
    ),
  );
  configureTlsPinning(dio);
  return dio;
}

/// Backend client with [baseDio]'s certificate pinning but caller-supplied
/// options — used by clients that are not the shared `/v1` session client
/// (e.g. the `/health` probe, which targets the app root and needs short
/// timeouts). Keeping pinning here means no backend call can silently skip it.
Dio pinnedDio(BaseOptions options, {bool releaseMode = kReleaseMode}) {
  final baseUrl = options.baseUrl;
  if (isInsecureReleaseBuild(baseUrl, releaseMode: releaseMode)) {
    throw StateError('API_BASE_URL must use https:// in release builds.');
  }
  final dio = Dio(options);
  configureTlsPinning(dio);
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (requestOptions, handler) {
        if (isInsecureReleaseBuild(
          requestOptions.uri.toString(),
          releaseMode: releaseMode,
        )) {
          handler.reject(
            DioException(
              requestOptions: requestOptions,
              type: DioExceptionType.connectionError,
              error: StateError(
                'API_BASE_URL must use https:// in release builds.',
              ),
            ),
          );
          return;
        }
        handler.next(requestOptions);
      },
    ),
  );
  return dio;
}

/// Dio client for the FastAPI backend.
///
/// Auth: user Bearer JWT on every `/vpn-*` call
/// (OAuth2PasswordBearer, tokenUrl `.../auth/login`), issued by the login
/// screen and renewed by [AuthController]. [onUnauthorized] runs once per
/// 401: when it returns true the original request is retried a single time
/// (guarded by `extra['authRetried']`, `/auth/*` calls never retry).
Dio buildDio({
  required Future<String?> Function() tokenReader,
  Future<bool> Function()? onUnauthorized,
}) {
  final dio = baseDio();

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        stampRequest(options);
        final token = await tokenReader();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (e, handler) async {
        final status = e.response?.statusCode;
        if (status == 401 &&
            onUnauthorized != null &&
            e.requestOptions.extra['authRetried'] != true &&
            !e.requestOptions.path.contains('/auth/')) {
          e.requestOptions.extra['authRetried'] = true;
          final refreshed = await onUnauthorized();
          if (refreshed) {
            try {
              return handler.resolve(await dio.fetch(e.requestOptions));
            } on DioException catch (retryErr) {
              return handler.reject(retryErr);
            }
          }
        }
        rejectMappedError(handler, e, area: 'api');
      },
    ),
  );

  return dio;
}

/// Maps a response-less Dio failure to a user-facing error. Timeouts stay
/// distinct from offline, and TLS/certificate rejections (including a
/// `TLS_PIN_SPKI_SHA256` mismatch) get their own kind so they never masquerade
/// as airplane mode. Shared by the VPN and auth interceptors.
ApiException transportError(DioException e) {
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout) {
    return const ApiException(
      ApiErrorKind.network,
      'Request timed out. Check your connection and retry.',
    );
  }
  if (e.type == DioExceptionType.badCertificate) {
    return const ApiException(
      ApiErrorKind.tls,
      'Secure connection failed (certificate rejected). '
      'Check your network settings and retry.',
    );
  }
  return const ApiException(ApiErrorKind.network, 'No network connection.');
}

/// Unwraps a [ApiException] from a caught error, if present.
ApiException? asVpnError(Object e) {
  if (e is DioException && e.error is ApiException) {
    return e.error as ApiException;
  }
  return null;
}

/// True for pure transport failures (backend unreachable): a timeout, a
/// TLS/certificate rejection, or a connection error — as opposed to an
/// app-level HTTP rejection, which proves the backend is reachable and must
/// never stop the tunnel. `unknown` kinds (429, 500, unmatched 409, …) are
/// deliberately not transport. Shared by the status poll and the
/// switch/rotate/heal paths.
bool isTransportFailure(Object e) {
  if (e is TimeoutException) return true;
  if (e is DioException) {
    final kind = asVpnError(e)?.kind;
    return kind == ApiErrorKind.network ||
        kind == ApiErrorKind.tls ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError;
  }
  return false;
}
