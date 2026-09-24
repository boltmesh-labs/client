// Shared VPN state-test harness: the recording Dio, the canonical JSON
// payloads, the backend-error factories and the fixed diagnostic-probe
// doubles that every `test/features/vpn/state/` suite otherwise re-declares.
//
// Kept free of app state-layer imports so it can be imported anywhere without
// pulling the controller/provider graph (the tests import `vpn_providers`
// themselves). `fakes.dart` stays the lower layer of concrete doubles.

import 'package:boltmesh/core/errors.dart';
import 'package:dio/dio.dart';

import 'fakes.dart' as support;

/// Canonical successful dial payload (backend `DialOut`).
Map<String, dynamic> dialJson({
  String deviceId = 'dev-1',
  String serverId = 'srv-1',
  String serverName = 'one',
  String assignedIp = '10.8.0.5',
  String endpoint = '203.0.113.10',
  int wgPort = 51820,
  String wgDns = '10.8.0.1',
  String wgPublicKey = 'SRV',
  String? clientPublicKey,
}) => {
  'id': deviceId,
  'assigned_ip': assignedIp,
  'server_id': serverId,
  'server_name': serverName,
  'endpoint': endpoint,
  'wg_port': wgPort,
  'wg_dns': wgDns,
  'wg_public_key': wgPublicKey,
  // Omitted when null: existing suites assert the pre-field behavior. A suite
  // exercising key reconciliation supplies the server-side peer key.
  'client_public_key': ?clientPublicKey,
};

/// [dialJson] for the same server after a reboot rotated its WireGuard key.
Map<String, dynamic> rotatedDialJson() => {
  ...dialJson(),
  'wg_public_key': 'SRV2',
};

/// Successful `GET …/status` payload.
Map<String, dynamic> activeStatusJson({
  String deviceId = 'dev-1',
  String tier = 'pro',
  int maxDevices = 5,
  int activeDevices = 2,
  String subscriptionExpiresAt = '2026-06-01T00:00:00Z',
}) => {
  'device_id': deviceId,
  'status': 'active',
  'suspended_reason': null,
  'tier': tier,
  'max_devices': maxDevices,
  'active_devices': activeDevices,
  'subscription_expires_at': subscriptionExpiresAt,
};

/// `GET …/status` payload for a lapsed subscription.
Map<String, dynamic> suspendedStatusJson() => {
  ...activeStatusJson(),
  'status': 'suspended',
  'suspended_reason': 'subscription_lapsed',
  'subscription_expires_at': '2026-01-01T00:00:00Z',
};

/// Receive-timeout transport failure (backend unreachable, no response).
DioException networkTimeout(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.receiveTimeout,
  error: const ApiException(
    ApiErrorKind.network,
    'Request timed out. Check your connection and retry.',
  ),
);

/// 404 with `DEVICE_NO_ACTIVE_PEER` (device exists, no bound peer).
DioException peerless(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 404,
    data: const {
      'detail': 'Device has no active peer.',
      'code': 'DEVICE_NO_ACTIVE_PEER',
    },
  ),
  error: const ApiException(
    ApiErrorKind.noActivePeer,
    'No active connection. Binding a fresh peer…',
    404,
    'DEVICE_NO_ACTIVE_PEER',
  ),
);

/// 404 with `DEVICE_NOT_FOUND` (device revoked/removed server-side).
DioException missingDevice(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 404,
    data: const {'detail': 'Device not found.', 'code': 'DEVICE_NOT_FOUND'},
  ),
  error: const ApiException(
    ApiErrorKind.notFound,
    'Device or server not found. Reprovision this device.',
    404,
    'DEVICE_NOT_FOUND',
  ),
);

/// 409 already-connected (connect/switch raced a live peer).
DioException alreadyConnected(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 409,
    data: const {'detail': 'Device is already connected.'},
  ),
  error: const ApiException(
    ApiErrorKind.alreadyConnected,
    'Already connected. Loading existing config.',
    409,
  ),
);

/// 409 idempotency conflict (provision replay).
DioException idempotencyConflict(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 409,
    data: const {'detail': 'Idempotency-Key already used.'},
  ),
  error: const ApiException(
    ApiErrorKind.idempotencyConflict,
    'Provision already in flight. Retrying with the same key.',
    409,
  ),
);

/// Dio that records every outgoing `METHOD:path` into [events] and answers
/// from [respond] (return the response body, or throw a [DioException] to
/// simulate a failure).
Dio recordingDio(
  List<String> events,
  dynamic Function(RequestOptions options) respond,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        events.add('${options.method}:${options.path}');
        try {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: respond(options),
            ),
          );
        } on DioException catch (e) {
          handler.reject(e);
        }
      },
    ),
  );
  return dio;
}

/// Fixed-value diagnostic-probe doubles for the "link up, gateway dead,
/// control plane unreachable" path the legacy heal ladder expects.
class OnlineNetworkMonitor extends support.FakeNetworkMonitor {
  OnlineNetworkMonitor() : super(true);
}

class DeadGatewayProbe extends support.FakeGatewayProbe {
  DeadGatewayProbe() : super(false);
}

class DownControlProbe extends support.FakeControlProbe {
  DownControlProbe() : super(false);
}
