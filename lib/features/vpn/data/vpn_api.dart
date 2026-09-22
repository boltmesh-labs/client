import 'package:dio/dio.dart';

import 'models.dart';

/// Thin client over backend/app/vpn/routers/devices.py + regions.py.
///
/// Provision/connect/switch share the backend retry loop over the
/// client-supplied key; switch requires exactly one of
/// server_id/region_id; connect takes an optional target (nulls mean the
/// backend picks the global lowest-load server).
///
/// The `if (... != null)` guards below intentionally stay verbose: a
/// null-aware entry (`?key: value`) would still send an explicit null,
/// violating the backend's exactly-one-target contract.
// ignore_for_file: use_null_aware_elements
class VpnApi {
  final Dio _dio;
  const VpnApi(this._dio);

  Future<List<Region>> regions({CancelToken? cancelToken}) async {
    final r = await _dio.get<List<dynamic>>(
      '/vpn-regions',
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
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/vpn-devices',
      data: {
        'name': name,
        'platform': platform,
        'public_key': publicKey,
        if (serverId != null) 'server_id': serverId,
        if (regionId != null) 'region_id': regionId,
      },
      options: Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  Future<DialParams> config(String deviceId, {CancelToken? cancelToken}) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/vpn-devices/$deviceId/config',
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  Future<DialParams> connect({
    required String deviceId,
    required String publicKey,
    String? serverId,
    String? regionId,
    CancelToken? cancelToken,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/vpn-devices/$deviceId/connect',
      data: {
        'public_key': publicKey,
        if (serverId != null) 'server_id': serverId,
        if (regionId != null) 'region_id': regionId,
      },
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  Future<DialParams> switchServer({
    required String deviceId,
    required String publicKey,
    String? serverId,
    String? regionId,
    CancelToken? cancelToken,
  }) async {
    // Backend 422s unless exactly one target is set.
    if ((serverId == null) == (regionId == null)) {
      throw ArgumentError('switch requires exactly one of serverId/regionId');
    }
    final r = await _dio.post<Map<String, dynamic>>(
      '/vpn-devices/$deviceId/switch',
      data: {
        'public_key': publicKey,
        if (serverId != null) 'server_id': serverId,
        if (regionId != null) 'region_id': regionId,
      },
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  /// In-place key move: same server and overlay IP, peer moves to the
  /// supplied key (backend `POST /vpn-devices/{id}/rotate-keys`).
  Future<DialParams> rotateKeys({
    required String deviceId,
    required String publicKey,
    CancelToken? cancelToken,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/vpn-devices/$deviceId/rotate-keys',
      data: {'public_key': publicKey},
      cancelToken: cancelToken,
    );
    return DialParams.fromJson(r.data as Map<String, dynamic>);
  }

  /// Lightweight heartbeat: session validity + tier/quota snapshot, no
  /// config (backend `GET /vpn-devices/{id}/status`). Poll no faster than
  /// [Env.statusPollInterval] against the session-budgeted rate limiter.
  Future<DeviceStatus> status(String deviceId) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/vpn-devices/$deviceId/status',
    );
    return DeviceStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Idempotent teardown: works with a lapsed subscription, returns
  /// `disconnected_peers=0` when already peerless.
  Future<void> disconnect(String deviceId) async {
    await _dio.post<void>('/vpn-devices/$deviceId/disconnect');
  }

  /// Hard revoke: deletes the device row (frees the `max_devices` slot).
  /// Unknown IDs surface as 404 — callers treat that as success (already
  /// revoked). Must be called after [disconnect] so the tunnel is down
  /// before the server-side row disappears.
  Future<void> revoke(String deviceId) async {
    await _dio.delete<void>('/vpn-devices/$deviceId');
  }
}
