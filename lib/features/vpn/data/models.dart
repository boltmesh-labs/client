// DTOs for backend/app/vpn schemas (devices.py, regions.py).
// Field names match the JSON contract exactly.

import 'dart:convert';

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

/// Per-region tunnel obfuscation descriptor (backend `obfuscation` object).
///
/// Null or `mode: ''` is the native WireGuard data plane. `awg` selects the
/// obfuscated data plane with a complete parameter set — both tunnel ends
/// must run identical parameters, so a descriptor with a mode but no params
/// is a misconfiguration the client treats as native rather than building a
/// half-obfuscated tunnel that can never handshake.
@freezed
abstract class Obfuscation with _$Obfuscation {
  const Obfuscation._();

  const factory Obfuscation({
    @Default('') String mode,
    ObfuscationParams? params,
  }) = _Obfuscation;

  factory Obfuscation.fromJson(Map<String, Object?> json) =>
      _$ObfuscationFromJson(json);

  /// True when this descriptor selects the obfuscated (AmneziaWG) data
  /// plane *and* carries the complete parameter set to build a conf with.
  bool get isAwg => mode == 'awg' && params != null && params!.isComplete;
}

/// AmneziaWG obfuscation parameters (`params` object). Mirrors the backend
/// contract: counts/sizes as numbers, magic-header ranges as `[lo, hi]`
/// pairs. Fields decode leniently (nullable) so a partial descriptor from a
/// buggy backend never breaks the whole dial payload — [isComplete] is the
/// gate, and both tunnel ends must run identical values, so an incomplete
/// set is never emitted into a conf.
@freezed
abstract class ObfuscationParams with _$ObfuscationParams {
  const ObfuscationParams._();

  const factory ObfuscationParams({
    @JsonKey(name: 'jc') int? jc,
    @JsonKey(name: 'jmin') int? jmin,
    @JsonKey(name: 'jmax') int? jmax,
    @JsonKey(name: 's1') int? s1,
    @JsonKey(name: 's2') int? s2,
    @JsonKey(name: 's3') int? s3,
    @JsonKey(name: 's4') int? s4,
    @JsonKey(name: 'h1') List<int>? h1,
    @JsonKey(name: 'h2') List<int>? h2,
    @JsonKey(name: 'h3') List<int>? h3,
    @JsonKey(name: 'h4') List<int>? h4,
  }) = _ObfuscationParams;

  factory ObfuscationParams.fromJson(Map<String, Object?> json) =>
      _$ObfuscationParamsFromJson(json);

  /// True when every parameter is present and well-formed: every header pair
  /// is a two-element `[lo, hi]` range with `lo <= hi`. An incomplete set is
  /// never emitted into a conf (see [Obfuscation.isAwg]).
  bool get isComplete =>
      jc != null &&
      jmin != null &&
      jmax != null &&
      s1 != null &&
      s2 != null &&
      s3 != null &&
      s4 != null &&
      h1 != null &&
      h2 != null &&
      h3 != null &&
      h4 != null &&
      jc! >= 0 &&
      jmin! >= 0 &&
      jmax! >= 0 &&
      s1! >= 0 &&
      s2! >= 0 &&
      s3! >= 0 &&
      s4! >= 0 &&
      jmin! <= jmax! &&
      _rangeValid(h1) &&
      _rangeValid(h2) &&
      _rangeValid(h3) &&
      _rangeValid(h4);

  static bool _rangeValid(List<int>? range) =>
      range != null &&
      range.length == 2 &&
      range[0] >= 0 &&
      range[0] <= range[1];
}

/// Per-device stream-transport credential (backend `stream` object).
///
/// Carries everything the helper's in-process bridge needs to carry the
/// tunnel's datagrams to the node inside a TLS session: the node's address and
/// the name its certificate is issued for, the pins that authenticate it, and
/// the pre-shared key that authenticates this device to the node.
///
/// Every field is validated against the same sizes the daemon enforces
/// (32-byte PSK, 16-byte client id, 32-byte SHA-256 pins, base64), so a
/// malformed descriptor can never produce a transport that is built and then
/// refused: [isUsable] is the only gate, and an incomplete credential set means
/// the rung is not offered at all.
///
/// This is deliberately on [DialParams] and *not* on [DiscoveryServer]. The
/// PSK is a per-device secret, and the discovery payload is fetched by every
/// client of a region — a credential that authenticates a device to a node
/// cannot live in a shared listing.
@freezed
abstract class StreamTransport with _$StreamTransport {
  const StreamTransport._();

  const factory StreamTransport({
    // `host[:port]`; a bare host means 443, the only port a stream dials.
    @JsonKey(name: 'server') @Default('') String server,
    // The SNI presented and the name the pin is checked against.
    @JsonKey(name: 'server_name') @Default('') String serverName,
    // SHA-256 digests of the node's leaf SPKI, base64. Several are allowed so
    // the node can rotate its key without a client release.
    @JsonKey(name: 'spki_sha256') @Default(<String>[]) List<String> spkiPins,
    // The device's pre-shared key, base64. Never logged.
    @JsonKey(name: 'psk') @Default('') String psk,
    // The device's stream identity, base64.
    @JsonKey(name: 'client_id') @Default('') String clientId,
  }) = _StreamTransport;

  factory StreamTransport.fromJson(Map<String, Object?> json) =>
      _$StreamTransportFromJson(json);

  /// True when the credential set is complete and well-formed.
  ///
  /// Mirrors the daemon's `TransportSpec` validation field for field, so a
  /// descriptor this accepts is one the helper will accept. Anything less and
  /// the stream rung is simply not offered.
  bool get isUsable =>
      server.trim().isNotEmpty &&
      serverName.trim().isNotEmpty &&
      spkiPins.isNotEmpty &&
      spkiPins.every((pin) => _base64OfSize(pin, streamSPKISize)) &&
      _base64OfSize(psk, streamPSKSize) &&
      _base64OfSize(clientId, streamClientIDSize);
}

/// Byte sizes the stream credential fields must decode to. Mirrored from the
/// helper's protocol package so the two sides cannot drift.
const streamPSKSize = 32;
const streamClientIDSize = 16;
const streamSPKISize = 32;

/// True when [value] is standard base64 decoding to exactly [size] bytes.
bool _base64OfSize(String value, int size) {
  if (value.isEmpty) return false;
  try {
    return base64.decode(value).length == size;
  } on FormatException {
    return false;
  }
}

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
    // Per-region obfuscation descriptor. Null on backends that predate the
    // field (native data plane).
    @JsonKey(name: 'obfuscation') Obfuscation? obfuscation,
    // This device's stream-transport credential. Null on backends that predate
    // the field, and for a region whose node runs no ingress.
    @JsonKey(name: 'stream') StreamTransport? stream,
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
    // Per-region obfuscation descriptor. Null on backends that predate the
    // field (native data plane).
    @JsonKey(name: 'obfuscation') Obfuscation? obfuscation,
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
