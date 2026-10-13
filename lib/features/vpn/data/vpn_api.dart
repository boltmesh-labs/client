import 'package:dio/dio.dart';

import '../../../core/errors.dart';
import 'models.dart';

/// Thin client over backend/app/vpn/routers/devices.py + regions.py.
///
/// Two session verbs, no peer knowledge: `connect` ensures the client key is
/// bound (creating, replaying, rotating, or moving the server-side peer as
/// needed) and `disconnect` releases it. No target means "stay where I am" (or
/// the global lowest-load server when nothing is bound); a target is a pick
/// from discovery.
///
/// The `if (... != null)` guards below intentionally stay verbose: a
/// null-aware entry (`?key: value`) would still send an explicit null, which
/// the backend reads as "no target" rather than the value.
// ignore_for_file: use_null_aware_elements
class VpnApi {
  final Dio _dio;

  /// Hard wall-clock budget for one VPN API operation. Dio's receive timeout
  /// only bounds inactivity; this bounds a server that keeps trickling bytes.
  static const requestDeadline = Duration(seconds: 5);

  /// Shorter deadline for disconnect/revoke operations to avoid long waits
  /// when the backend is unreachable. The local tunnel teardown is authoritative,
  /// so a failed server-side release should not block the UI.
  static const disconnectDeadline = Duration(seconds: 3);

  final Duration deadline;

  const VpnApi(this._dio, {this.deadline = requestDeadline});

  /// Runs one API operation with a total deadline and cancels the in-flight
  /// request when the deadline expires. A caller-provided token is reused so
  /// higher-level probe/fallback cancellation remains effective.
  Future<T> _request<T>(
    String path,
    Future<T> Function(CancelToken token) call, {
    CancelToken? cancelToken,
    Duration? deadline,
  }) {
    final token = cancelToken ?? CancelToken();
    final effectiveDeadline = deadline ?? this.deadline;
    return call(token).timeout(
      effectiveDeadline,
      onTimeout: () {
        token.cancel('$path exceeded total deadline');
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.receiveTimeout,
          error: const ApiException(
            ApiErrorKind.network,
            'Request timed out. Check your connection and retry.',
          ),
        );
      },
    );
  }

  Future<List<Region>> regions({CancelToken? cancelToken}) async {
    final r = await _request(
      '/vpn-regions',
      (token) => _dio.get<List<dynamic>>('/vpn-regions', cancelToken: token),
      cancelToken: cancelToken,
    );
    return (r.data ?? [])
        .map((e) => Region.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DialParams> provision({
    required String name,
    required String platform,
    required String publicKey,
    String? serverId,
    String? regionId,
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    final r = await _request(
      '/vpn-devices',
      (token) => _dio.post<Map<String, dynamic>>(
        '/vpn-devices',
        data: {
          'name': name,
          'platform': platform,
          'public_key': publicKey,
          if (serverId != null) 'server_id': serverId,
          if (regionId != null) 'region_id': regionId,
        },
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
        cancelToken: token,
      ),
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  /// Ensure the client key is bound on a server, and return its dial params.
  ///
  /// The backend owns every peer decision: peerless binds a fresh peer, the
  /// same key on the requested server replays unchanged, a different key
  /// rotates in place, and a named target moves the peer. So the caller never
  /// has to know whether it holds a peer, which key the server holds, or where
  /// it is bound.
  Future<DialParams> connect({
    required String deviceId,
    required String publicKey,
    String? serverId,
    String? regionId,
    CancelToken? cancelToken,
  }) async {
    final r = await _request(
      '/vpn-devices/$deviceId/connect',
      (token) => _dio.post<Map<String, dynamic>>(
        '/vpn-devices/$deviceId/connect',
        data: {
          'public_key': publicKey,
          if (serverId != null) 'server_id': serverId,
          if (regionId != null) 'region_id': regionId,
        },
        cancelToken: token,
      ),
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  /// Lightweight heartbeat: session validity + tier/quota snapshot, no
  /// config (backend `GET /vpn-devices/{id}/status`). Poll no faster than
  /// [Env.statusPollInterval] against the session-budgeted rate limiter.
  Future<DeviceStatus> status(
    String deviceId, {
    CancelToken? cancelToken,
  }) async {
    final r = await _request(
      '/vpn-devices/$deviceId/status',
      (token) => _dio.get<Map<String, dynamic>>(
        '/vpn-devices/$deviceId/status',
        cancelToken: token,
      ),
      cancelToken: cancelToken,
    );
    return DeviceStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Health of the node serving this device (backend
  /// `GET /vpn-devices/{id}/server-status`). Lets the controller attribute a
  /// dead tunnel to its node instead of inferring it from a local probe; the
  /// discovery list cannot, because it only ever lists `online` rows.
  ///
  /// Shares the status poll's cadence and session-keyed budget, so the pair
  /// costs 2 of the backend's 30 requests/min. Callers must treat a failure
  /// as unknown, never as a dead node.
  Future<ServerStatus> serverStatus(
    String deviceId, {
    CancelToken? cancelToken,
  }) async {
    final r = await _request(
      '/vpn-devices/$deviceId/server-status',
      (token) => _dio.get<Map<String, dynamic>>(
        '/vpn-devices/$deviceId/server-status',
        cancelToken: token,
      ),
      cancelToken: cancelToken,
    );
    return ServerStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Idempotent teardown: works with a lapsed subscription, returns
  /// `disconnected_peers=0` when already peerless.
  Future<void> disconnect(String deviceId, {CancelToken? cancelToken}) async {
    await _request(
      '/vpn-devices/$deviceId/disconnect',
      (token) => _dio.post<void>(
        '/vpn-devices/$deviceId/disconnect',
        cancelToken: token,
      ),
      cancelToken: cancelToken,
      deadline: disconnectDeadline,
    );
  }

  /// Hard revoke: deletes the device row (frees the `max_devices` slot).
  /// Unknown IDs surface as 404 — callers treat that as success (already
  /// revoked). Must be called after [disconnect] so the tunnel is down
  /// before the server-side row disappears.
  Future<void> revoke(String deviceId, {CancelToken? cancelToken}) async {
    await _request(
      '/vpn-devices/$deviceId',
      (token) =>
          _dio.delete<void>('/vpn-devices/$deviceId', cancelToken: token),
      cancelToken: cancelToken,
      deadline: disconnectDeadline,
    );
  }
}
