// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_DialParams _$DialParamsFromJson(Map<String, dynamic> json) => _DialParams(
  deviceId: json['id'] as String,
  assignedIp: json['assigned_ip'] as String,
  serverId: json['server_id'] as String,
  serverName: json['server_name'] as String? ?? '',
  endpoint: json['endpoint'] as String,
  wgPort: (json['wg_port'] as num).toInt(),
  wgDns: json['wg_dns'] as String,
  wgPublicKey: json['wg_public_key'] as String,
  clientPublicKey: json['client_public_key'] as String?,
);

Map<String, dynamic> _$DialParamsToJson(_DialParams instance) =>
    <String, dynamic>{
      'id': instance.deviceId,
      'assigned_ip': instance.assignedIp,
      'server_id': instance.serverId,
      'server_name': instance.serverName,
      'endpoint': instance.endpoint,
      'wg_port': instance.wgPort,
      'wg_dns': instance.wgDns,
      'wg_public_key': instance.wgPublicKey,
      'client_public_key': instance.clientPublicKey,
    };

_DiscoveryServer _$DiscoveryServerFromJson(Map<String, dynamic> json) =>
    _DiscoveryServer(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      endpoint: _readDialHost(json, 'endpoint') as String? ?? '',
      wgPort: (json['wg_port'] as num).toInt(),
      wgDns: json['wg_dns'] as String? ?? '',
      wgPublicKey: json['wg_public_key'] as String?,
      activePeers: (json['active_peers'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$DiscoveryServerToJson(_DiscoveryServer instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'endpoint': instance.endpoint,
      'wg_port': instance.wgPort,
      'wg_dns': instance.wgDns,
      'wg_public_key': instance.wgPublicKey,
      'active_peers': instance.activePeers,
    };

_Region _$RegionFromJson(Map<String, dynamic> json) => _Region(
  id: json['id'] as String,
  name: json['name'] as String? ?? '',
  countryCode: json['country_code'] as String?,
  servers:
      (json['servers'] as List<dynamic>?)
          ?.map((e) => DiscoveryServer.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$RegionToJson(_Region instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'country_code': instance.countryCode,
  'servers': instance.servers,
};

_DeviceStatus _$DeviceStatusFromJson(Map<String, dynamic> json) =>
    _DeviceStatus(
      deviceId: json['device_id'] as String,
      status: json['status'] as String,
      suspendedReason: json['suspended_reason'] as String?,
      tier: json['tier'] as String?,
      maxDevices: (json['max_devices'] as num?)?.toInt(),
      activeDevices: (json['active_devices'] as num?)?.toInt() ?? 0,
      subscriptionExpiresAt: _parseExpiry(json['subscription_expires_at']),
    );

Map<String, dynamic> _$DeviceStatusToJson(
  _DeviceStatus instance,
) => <String, dynamic>{
  'device_id': instance.deviceId,
  'status': instance.status,
  'suspended_reason': instance.suspendedReason,
  'tier': instance.tier,
  'max_devices': instance.maxDevices,
  'active_devices': instance.activeDevices,
  'subscription_expires_at': instance.subscriptionExpiresAt?.toIso8601String(),
};
