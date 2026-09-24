import 'package:boltmesh/core/dio_client.dart';
import 'package:boltmesh/core/errors.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('401 prompts login', () {
    expect(friendlyMessage(401, 'x'), contains('log in again'));
    expect(kindFor(401, ''), ApiErrorKind.unauthorized);
  });

  test('404 treated as reprovision', () {
    expect(kindFor(404, 'nope'), ApiErrorKind.notFound);
    expect(friendlyMessage(404, 'nope'), contains('Reprovision'));
  });

  test('404 peerless distinguished from missing device', () {
    expect(
      kindFor(404, 'Device has no active peer.'),
      ApiErrorKind.noActivePeer,
    );
    expect(
      kindFor(404, 'Device not found.', 'DEVICE_NO_ACTIVE_PEER'),
      ApiErrorKind.noActivePeer,
    );
    expect(
      kindFor(404, 'Device not found.', 'DEVICE_NOT_FOUND'),
      ApiErrorKind.notFound,
    );
    expect(
      friendlyMessage(404, 'Device has no active peer.'),
      contains('fresh peer'),
    );
  });

  test('409 already-connected distinguished from key reuse', () {
    expect(kindFor(409, 'already connected'), ApiErrorKind.alreadyConnected);
    expect(kindFor(409, 'public key in use'), ApiErrorKind.keyInUse);
    // The real backend detail for PUBLIC_KEY_IN_USE contains "already", so
    // the classifier must not shadow key reuse with the already-connected
    // branch (its fresh-key retry would otherwise be unreachable).
    expect(
      kindFor(
        409,
        'This WireGuard public key is already registered to another device.',
        'PUBLIC_KEY_IN_USE',
      ),
      ApiErrorKind.keyInUse,
    );
  });

  test('503 signals capacity', () {
    expect(kindFor(503, 'no servers'), ApiErrorKind.noCapacity);
  });

  test('403 device limit distinguished from other forbidden errors', () {
    expect(kindFor(403, 'device limit reached'), ApiErrorKind.deviceLimit);
    expect(kindFor(403, '', 'DEVICE_LIMIT_EXCEEDED'), ApiErrorKind.deviceLimit);
    expect(
      friendlyMessage(403, '', 'DEVICE_LIMIT_EXCEEDED'),
      contains('Device limit'),
    );
    expect(
      kindFor(403, 'subscription expired'),
      ApiErrorKind.forbiddenNoSubscription,
    );
    expect(kindFor(403, '', 'ACCOUNT_INACTIVE'), ApiErrorKind.forbidden);
    expect(
      friendlyMessage(403, '', 'DEVICE_INACTIVE'),
      contains('device is inactive'),
    );
  });

  test('409 idempotency conflict', () {
    expect(
      kindFor(409, 'Idempotency-Key already used'),
      ApiErrorKind.idempotencyConflict,
    );
    expect(
      friendlyMessage(409, 'Idempotency-Key already used'),
      contains('in flight'),
    );
  });

  test('409 unknown detail stays unknown', () {
    expect(kindFor(409, 'something else'), ApiErrorKind.unknown);
  });

  test('422 validation and unknown status', () {
    expect(kindFor(422, 'public_key bad'), ApiErrorKind.validation);
    expect(friendlyMessage(422, 'public_key bad'), contains('Invalid request'));
    expect(kindFor(null, 'boom'), ApiErrorKind.unknown);
    expect(friendlyMessage(null, ''), contains('Request failed'));
  });

  test('gateway/proxy outages map to network with a clean message', () {
    // 502/504 mean the proxy never reached the backend: transport.
    for (final status in [502, 504]) {
      expect(kindFor(status, 'boom'), ApiErrorKind.network);
      expect(friendlyMessage(status, 'boom'), contains('Backend unreachable'));
    }
    expect(kindFor(503, 'no servers'), ApiErrorKind.noCapacity);
  });

  test('500 is an app-level answer, never transport', () {
    // The backend answered, so the kind must not be network (which would let
    // the VPN stop a live tunnel) and the detail is preserved.
    expect(kindFor(500, 'database exploded'), ApiErrorKind.unknown);
    expect(
      friendlyMessage(500, 'database exploded'),
      contains('database exploded'),
    );
  });

  test('proxy HTML error pages never reach the UI', () {
    const html =
        '<html><head><title>502 Bad Gateway</title></head>'
        '<body><center><h1>502 Bad Gateway</h1></center></body></html>';
    expect(friendlyMessage(502, html), contains('Backend unreachable'));
    expect(friendlyMessage(502, html), isNot(contains('<html')));
    expect(friendlyMessage(502, html), isNot(contains('Bad Gateway</')));
    expect(friendlyMessage(200, html), contains('Backend unreachable'));
    expect(looksLikeHtmlBody(html), isTrue);
    expect(looksLikeHtmlBody('{"detail":"boom"}'), isFalse);
    expect(looksLikeHtmlBody(''), isFalse);
  });

  test('transportError keeps timeout, TLS and offline distinct', () {
    final opts = RequestOptions(path: '/auth/login');

    final timeout = transportError(
      DioException(requestOptions: opts, type: DioExceptionType.sendTimeout),
    );
    expect(timeout.kind, ApiErrorKind.network);
    expect(timeout.message, contains('timed out'));

    final tls = transportError(
      DioException(requestOptions: opts, type: DioExceptionType.badCertificate),
    );
    expect(tls.kind, ApiErrorKind.tls);
    expect(tls.message, contains('certificate'));

    final offline = transportError(
      DioException(
        requestOptions: opts,
        type: DioExceptionType.connectionError,
      ),
    );
    expect(offline.kind, ApiErrorKind.network);
    expect(offline.message, contains('No network'));
  });

  test('429 maps to a dedicated rate-limited kind', () {
    expect(kindFor(429, 'Rate limit exceeded.'), ApiErrorKind.rateLimited);
    expect(kindFor(429, ''), ApiErrorKind.rateLimited);
    expect(friendlyMessage(429, ''), contains('Rate limit'));
    // The backend detail is preserved when present.
    expect(
      friendlyMessage(429, 'Rate limit exceeded. Please try again later.'),
      'Rate limit exceeded. Please try again later.',
    );
  });

  test('parseRetryAfterHeader reads delta-seconds', () {
    expect(parseRetryAfterHeader('60'), const Duration(seconds: 60));
    expect(parseRetryAfterHeader(' 30 '), const Duration(seconds: 30));
    expect(parseRetryAfterHeader('0'), Duration.zero);
    expect(parseRetryAfterHeader('-5'), Duration.zero);
    expect(parseRetryAfterHeader(''), isNull);
    expect(parseRetryAfterHeader(null), isNull);
    expect(parseRetryAfterHeader('nonsense'), isNull);
    expect(parseRetryAfterHeader('Wed, 31 Feb 2027 08:49:37 GMT'), isNull);
  });

  test('parseRetryAfterHeader reads HTTP-date forms', () {
    // IMF-fixdate.
    expect(
      parseRetryAfterHeader('Sun, 06 Nov 1994 08:49:37 GMT'),
      Duration.zero,
    );
    // RFC 850.
    expect(
      parseRetryAfterHeader('Sunday, 06-Nov-94 08:49:37 GMT'),
      Duration.zero,
    );
    // asctime (note the double space before the single-digit day).
    expect(parseRetryAfterHeader('Sun Nov  6 08:49:37 1994'), Duration.zero);

    // A future date yields a positive wait close to the offset.
    final future = DateTime.now().toUtc().add(const Duration(minutes: 5));
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    final header =
        '${weekdays[future.weekday - 1]}, ${two(future.day)} '
        '${months[future.month - 1]} ${future.year} '
        '${two(future.hour)}:${two(future.minute)}:${two(future.second)} GMT';
    final parsed = parseRetryAfterHeader(header);
    expect(parsed, isNotNull);
    expect(parsed!.inSeconds, closeTo(300, 5));
  });
}
