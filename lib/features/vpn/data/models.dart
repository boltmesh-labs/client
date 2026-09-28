// DTOs for backend/app/vpn schemas (devices.py, regions.py).
// Field names match the JSON contract exactly.

import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';
part 'models.g.dart';

/// Discovery `endpoint` is optional server-side (null means clients dial
/// `public_ip` instead); fall back so a missing endpoint never kills the
/// whole region list. The `readValue` callback's trailing JSON key is
/// required by the signature but unused here (the keys are fixed).
Object? _readDialHost(Map<dynamic, dynamic> json, String _) {
  final endpoint = (json['endpoint'] as String?)?.trim();
  if (endpoint != null && endpoint.isNotEmpty) return endpoint;
  return (json['public_ip'] as String?)?.trim() ?? '';
}

DateTime? _parseExpiry(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? _serverHealthToWire(ServerHealth? value) => value?.wire;

@freezed
abstract class DialParams with _$DialParams {
  const factory DialParams({
    @JsonKey(name: 'id') required String deviceId,
    @JsonKey(name: 'assigned_ip') required String assignedIp,
    @JsonKey(name: 'server_id') required String serverId,
    @JsonKey(name: 'server_name') @Default('') String serverName,
    required String endpoint,
    @JsonKey(name: 'wg_port') required int wgPort,
    @JsonKey(name: 'wg_dns') required String wgDns,
    @JsonKey(name: 'wg_public_key') required String wgPublicKey,
    // The server's active peer public key for this device (`GET …/config` and
    // every bind response report it). Null on backends that predate the field;
    // when present the controller verifies the stored keypair matches before
    // starting a tunnel, repairing a divergence a lost bind response can leave.
    @JsonKey(name: 'client_public_key') String? clientPublicKey,
  }) = _DialParams;

  factory DialParams.fromJson(Map<String, Object?> json) =>
      _$DialParamsFromJson(json);
}

@freezed
abstract class DiscoveryServer with _$DiscoveryServer {
  const DiscoveryServer._();

  const factory DiscoveryServer({
    required String id,
    @Default('') String name,
    @JsonKey(readValue: _readDialHost) @Default('') String endpoint,
    @JsonKey(name: 'wg_port') required int wgPort,
    @JsonKey(name: 'wg_dns') @Default('') String wgDns,
    @JsonKey(name: 'wg_public_key') String? wgPublicKey,
    @JsonKey(name: 'active_peers') @Default(0) int activePeers,
  }) = _DiscoveryServer;

  factory DiscoveryServer.fromJson(Map<String, Object?> json) =>
      _$DiscoveryServerFromJson(json);
}

/// Health of the node serving this device (`GET …/server-status`).
///
/// The backend's own view of the node: `status` is heartbeat-driven and
/// swept to `offline` once the node stops reporting, so a client can tell
/// "my node is gone" apart from "my local path is broken". The discovery list
/// cannot make that distinction — it filters to `online` rows, so every server
/// it lists is healthy by construction.
///
/// Any value other than [ServerHealth.online] means move. Modeling the
/// backend enum as a Dart enum rather than a bool keeps that rule total: a
/// status added server-side later decodes to null and is treated as unknown
/// (absence of evidence) instead of silently reading as healthy.
@freezed
abstract class ServerStatus with _$ServerStatus {
  const ServerStatus._();

  const factory ServerStatus({
    @JsonKey(name: 'server_id') required String serverId,
    @Default('') String name,
    @JsonKey(
      name: 'status',
      fromJson: ServerHealth.fromWire,
      toJson: _serverHealthToWire,
    )
    ServerHealth? status,
    @JsonKey(name: 'active_peers') @Default(0) int activePeers,
  }) = _ServerStatus;

  factory ServerStatus.fromJson(Map<String, Object?> json) =>
      _$ServerStatusFromJson(json);

  /// The node is serving clients. The only state that is not a reason to move.
  bool get isOnline => status == ServerHealth.online;

  /// A positively-confirmed unhealthy node.
  ///
  /// False while [status] is null: an unparseable or absent read is unknown,
  /// never proof of death, and must not by itself drive a server move.
  bool get isUnhealthy => status != null && !isOnline;
}

@freezed
abstract class Region with _$Region {
  const Region._();

  const factory Region({
    required String id,
    @Default('') String name,
    @JsonKey(name: 'country_code') String? countryCode,
    @Default([]) List<DiscoveryServer> servers,
  }) = _Region;

  factory Region.fromJson(Map<String, Object?> json) => _$RegionFromJson(json);

  /// Regions with `servers: []` have no dialable capacity.
  bool get hasCapacity => servers.isNotEmpty;
}

/// Lightweight session status for `GET /vpn-devices/{id}/status` polling
/// (backend/app/vpn/routers/devices.py `get_device_status`).
/// No WireGuard material, no peer list. Revoked devices surface as 404,
/// never as a payload.
@freezed
abstract class DeviceStatus with _$DeviceStatus {
  const DeviceStatus._();

  const factory DeviceStatus({
    @JsonKey(name: 'device_id') required String deviceId,
    required String status,
    @JsonKey(name: 'suspended_reason') String? suspendedReason,
    String? tier,
    @JsonKey(name: 'max_devices') int? maxDevices,
    @JsonKey(name: 'active_devices') @Default(0) int activeDevices,
    @JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry)
    DateTime? subscriptionExpiresAt,
  }) = _DeviceStatus;

  factory DeviceStatus.fromJson(Map<String, Object?> json) =>
      _$DeviceStatusFromJson(json);

  bool get isSuspended => status == 'suspended';
}

/// Liveness of a serving node (backend `VpnServerStatusEnum`).
///
/// Mirrors the backend enum rather than collapsing to a bool so the
/// "act unless online" rule stays total: a status the backend adds later
/// decodes to null (unknown) instead of being silently read as healthy.
enum ServerHealth {
  online,
  provisioning,
  maintenance,
  offline,
  decommissioned,
  error;

  /// Wire value, for tests and logs.
  String get wire => name;

  static ServerHealth? fromWire(String? value) {
    if (value == null) return null;
    for (final v in values) {
      if (v.name == value) return v;
    }
    return null;
  }
}
