import 'dart:async';
import 'dart:io' show HttpStatus;
import 'dart:typed_data';

import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves a fixed outcome for every request. `flutter test` stubs
/// `HttpClient` (a real socket never reaches a local server), so the outcome
/// is injected at the adapter — `check()`'s own branching, the part the health
/// policy depends on, still runs for real.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions) _respond;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests++;
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status) => ResponseBody.fromString(
  '{}',
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Dio _dio(
  Future<ResponseBody> Function(RequestOptions) respond, {
  String baseUrl = 'https://control.example/health',
}) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  final adapter = _StubAdapter(respond);
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  group('ControlPlaneProbe.check', () {
    test('a 200 response proves the control plane reachable', () async {
      var endpoint = '';
      final probe = ControlPlaneProbe(
        apiBaseUrl: 'https://control.example/v1',
        loopbackApi: false,
        dioFactory: (health, _) {
          endpoint = health;
          return _dio((_) async => _json(HttpStatus.ok));
        },
      );

      expect(await probe.check(), isTrue);
      // `/health` is served at the app root, not under `/v1`.
      expect(endpoint, 'https://control.example/health');
    });

    test('a 5xx still proves reachable (only transport failure is dead)', () {
      // The health policy treats "server answered but unhealthy" and "no
      // answer at all" very differently, so the distinction has to hold.
      final probe = ControlPlaneProbe(
        loopbackApi: false,
        dioFactory: (_, _) =>
            _dio((_) async => _json(HttpStatus.serviceUnavailable)),
      );

      expect(probe.check(), completion(isTrue));
    });

    test('a 404 response still proves reachable', () {
      // Any HTTP response means the control plane answered; only a missing
      // response is a dead path.
      final probe = ControlPlaneProbe(
        loopbackApi: false,
        dioFactory: (_, _) => _dio((_) async => _json(HttpStatus.notFound)),
      );

      expect(probe.check(), completion(isTrue));
    });

    test('a transport failure is unreachable, not unknown', () {
      // The difference drives the heal ladder: false means the path is dead,
      // null means "do not know" and the caller stays fail-open.
      final probe = ControlPlaneProbe(
        loopbackApi: false,
        dioFactory: (_, _) => _dio(
          (options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
      );

      expect(probe.check(), completion(isFalse));
    });

    test(
      'a non-Dio adapter failure surfaces as a response-less DioException',
      () async {
        // Documents a real boundary: Dio wraps anything an adapter throws into
        // a `DioException` with no response, so an unexpected internal error
        // reaches the `false` (dead) branch, not the `null` (unknown) one. The
        // `catch (e) => null` arm therefore only covers a throw from outside
        // the request (e.g. building the client), not a failed request.
        final probe = ControlPlaneProbe(
          loopbackApi: false,
          dioFactory: (_, _) =>
              _dio((options) async => throw StateError('adapter blew up')),
        );

        expect(await probe.check(), isFalse);
      },
    );

    test('a loopback API is skipped as unknown, never probed', () {
      // A loopback/SSH-forwarded control plane shares the host underlay a
      // full tunnel routes away, so probing it would only report the
      // expected stranding. Skipped must be null, not true.
      final adapter = _StubAdapter((_) async => _json(HttpStatus.ok));
      final dio = Dio(BaseOptions(baseUrl: 'https://control.example/health'))
        ..httpClientAdapter = adapter;
      final probe = ControlPlaneProbe(
        loopbackApi: true,
        dioFactory: (_, _) => dio,
      );

      expect(probe.check(), completion(isNull));
      expect(adapter.requests, 0);
    });

    test('one client is reused across ticks, keyed by timeout', () async {
      // A fresh Dio per health tick would allocate and drop an HttpClient
      // every 15s.
      var built = 0;
      final probe = ControlPlaneProbe(
        loopbackApi: false,
        dioFactory: (_, _) {
          built++;
          return _dio((_) async => _json(HttpStatus.ok));
        },
      );

      await probe.check();
      await probe.check();
      expect(built, 1);

      // A different budget is a different client.
      await probe.check(timeout: const Duration(seconds: 3));
      expect(built, 2);
    });

    test('healthUrl strips the version prefix and trailing slashes', () {
      expect(
        ControlPlaneProbe.healthUrl('https://api.example/v1'),
        'https://api.example/health',
      );
      expect(
        ControlPlaneProbe.healthUrl('https://api.example/v1/'),
        'https://api.example/health',
      );
      // A base URL without `/v1` is left alone.
      expect(
        ControlPlaneProbe.healthUrl('https://api.example'),
        'https://api.example/health',
      );
    });
  });
}
