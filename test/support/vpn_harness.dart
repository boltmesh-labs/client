// Shared VPN state-test harness: the recording Dio, the canonical JSON
// payloads, the backend-error factories and the fixed diagnostic-probe
// doubles that every `test/features/vpn/state/` suite otherwise re-declares.
//
// Kept free of app state-layer imports so it can be imported anywhere without
// pulling the controller/provider graph (the tests import `vpn_providers`
// themselves). `fakes.dart` stays the lower layer of concrete doubles.

import 'dart:convert';

import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:dio/dio.dart';

import 'fakes.dart' as support;

/// Standard base64 of [bytes], for credential fields the daemon validates at
/// an exact size.
String base64Encode(List<int> bytes) => base64.encode(bytes);

/// Canonical dial payload (backend `VpnDeviceCreateOut`).
///
/// [transports] is the ladder the client walks, so a suite that wants a rung
/// passes [awgPort] or [stream] and this assembles the ordered entry for it —
/// which is what a node serving it actually sends. A rung whose payload was
/// withheld is simply absent from the list, the same shape as a node that never
/// served it, and that indistinguishability is the point of the withholding.
Map<String, dynamic> dialJson({
  String deviceId = 'dev-1',
  String serverId = 'srv-1',
  String serverName = 'one',
  String assignedIp = '10.8.0.5',
  String endpoint = '203.0.113.10',
  int wgPort = 51820,
  // The awg rung's own port. Naming it is what puts the entry in the list, the
  // way a node's `awg_enabled` puts it there.
  int? awgPort,
  String wgDns = '10.8.0.1',
  String wgPublicKey = 'SRV',
  String? clientPublicKey,
  // The awg entry's params. Omit for the canonical complete set; pass a raw map
  // to break it, or omit the entry entirely by leaving [awgPort] null.
  Object? awgParams,
  // The stream rung's credential. Omitted — rung absent — when null, matching a
  // node that runs no ingress or has issued this device no credential.
  Object? stream,
  // The obfuscated overlay's address. Derived from [awgPort] rather than passed:
  // a node serving the awg rung has to name the rung's ingredients *and* the
  // address its second device routes, or the client treats the rung as not
  // offered. Deriving keeps the awg suites from restating it and keeps the native
  // suites (no awgPort) on the absent path they mean to exercise.
  //
  // Pass `''` for the *incomplete* shapes the withholding has to survive — an
  // advertised rung with no address on the overlay it would need.
  String? awgAssignedIp,
  String awgDns = '10.9.0.1',
}) {
  final address = awgAssignedIp ?? '10.9.0.5';
  // The overlay address rides with the rung: a node serving no second device has
  // no second network for it to live on.
  final servesAwgAddress = awgPort != null && address.isNotEmpty;
  return {
    'id': deviceId,
    'assigned_ip': assignedIp,
    'awg_assigned_ip': ?(servesAwgAddress ? address : null),
    'awg_dns': ?(servesAwgAddress ? awgDns : null),
    'server_id': serverId,
    'server_name': serverName,
    'endpoint': endpoint,
    'wg_port': wgPort,
    'wg_dns': wgDns,
    'wg_public_key': wgPublicKey,
    // Omitted when null: existing suites assert the pre-field behavior. A suite
    // exercising key reconciliation supplies the server-side peer key.
    'client_public_key': ?clientPublicKey,
    // Cheapest first, which is the order the ladder walks. `native` is always
    // present: every node runs a stock device, and that is what makes it the rung
    // a client can always start on.
    'transports': [
      {'rung': 'native', 'port': wgPort},
      if (awgPort != null)
        {
          'rung': 'awg',
          'port': awgPort,
          'params': awgParams ?? awgObfuscationParamsJson(),
        },
      if (stream != null) {'rung': 'stream', 'port': 443, 'credential': stream},
    ],
  };
}

/// Canonical per-device stream-transport credential (a transport entry's
/// `credential` object): the node's TLS address, a certificate pin, and this
/// device's PSK and id.
Map<String, dynamic> streamTransportJson({
  String server = 'vpn.example.net:443',
  String serverName = 'vpn.example.net',
  Object? psk,
  Object? spkiSha256,
}) => {
  'server': server,
  'server_name': serverName,
  'spki_sha256': spkiSha256 ?? [base64Encode(List<int>.filled(32, 0xaa))],
  'psk': psk ?? base64Encode(List<int>.filled(32, 0xbb)),
  'client_id': base64Encode(List<int>.filled(16, 0xcc)),
};

/// Canonical complete AmneziaWG parameter set (a transport entry's `params`):
/// counts/sizes as numbers, magic-header ranges as `[lo, hi]` pairs. Both tunnel
/// ends must run identical values.
Map<String, dynamic> awgObfuscationParamsJson() => {
  'jc': 3,
  'jmin': 40,
  'jmax': 70,
  's1': 15,
  's2': 17,
  's3': 10,
  's4': 5,
  'h1': [115, 120],
  'h2': [130, 130],
  'h3': [150, 160],
  'h4': [171, 171],
};

/// [awgObfuscationParamsJson] decoded into the model, for suites that build a
/// rung entry rather than a whole dial payload.
ObfuscationParams awgObfuscationParams() =>
    ObfuscationParams.fromJson(awgObfuscationParamsJson());

/// The awg rung's ladder entry against [awgPort], for suites that need to put the
/// rung on a list they assemble by hand.
Map<String, dynamic> awgTransportJson({int port = 51821}) => {
  'rung': 'awg',
  'port': port,
  'params': awgObfuscationParamsJson(),
};

/// The stream rung's ladder entry against [stream].
Map<String, dynamic> streamTransportEntryJson(
  Map<String, dynamic> stream, {
  int port = 443,
}) => {'rung': 'stream', 'port': port, 'credential': stream};

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

/// Successful `GET …/server-status` payload ([VpnApi.serverStatus]).
Map<String, dynamic> onlineServerStatusJson({
  String serverId = 'srv-1',
  String name = 'node-1',
  int activePeers = 3,
}) => {
  'server_id': serverId,
  'name': name,
  'status': 'online',
  'active_peers': activePeers,
};

/// `GET …/server-status` payload for a node the backend has given up on.
/// The status is the raw wire value, so this is the only change needed to
/// exercise any non-`online` branch ([ServerHealth]).
Map<String, dynamic> serverStatusJson(String status) => {
  ...onlineServerStatusJson(),
  'status': status,
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

/// 404 with `DEVICE_NO_PEER` (device exists, no bound peer).
DioException peerless(RequestOptions o) => DioException(
  requestOptions: o,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: o,
    statusCode: 404,
    data: const {'detail': 'Device has no peer.', 'code': 'DEVICE_NO_PEER'},
  ),
  error: const ApiException(
    ApiErrorKind.noActivePeer,
    'No active connection. Binding a fresh peer…',
    404,
    'DEVICE_NO_PEER',
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
