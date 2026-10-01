// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Obfuscation _$ObfuscationFromJson(Map<String, dynamic> json) => _Obfuscation(
  mode: json['mode'] as String? ?? '',
  params: json['params'] == null
      ? null
      : ObfuscationParams.fromJson(json['params'] as Map<String, dynamic>),
);

Map<String, dynamic> _$ObfuscationToJson(_Obfuscation instance) =>
    <String, dynamic>{'mode': instance.mode, 'params': instance.params};

_ObfuscationParams _$ObfuscationParamsFromJson(
  Map<String, dynamic> json,
) => _ObfuscationParams(
  jc: (json['jc'] as num?)?.toInt(),
  jmin: (json['jmin'] as num?)?.toInt(),
  jmax: (json['jmax'] as num?)?.toInt(),
  s1: (json['s1'] as num?)?.toInt(),
  s2: (json['s2'] as num?)?.toInt(),
  s3: (json['s3'] as num?)?.toInt(),
  s4: (json['s4'] as num?)?.toInt(),
  h1: (json['h1'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList(),
  h2: (json['h2'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList(),
  h3: (json['h3'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList(),
  h4: (json['h4'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList(),
);

Map<String, dynamic> _$ObfuscationParamsToJson(_ObfuscationParams instance) =>
    <String, dynamic>{
      'jc': instance.jc,
      'jmin': instance.jmin,
      'jmax': instance.jmax,
      's1': instance.s1,
      's2': instance.s2,
      's3': instance.s3,
      's4': instance.s4,
      'h1': instance.h1,
      'h2': instance.h2,
      'h3': instance.h3,
      'h4': instance.h4,
    };

_StreamTransport _$StreamTransportFromJson(Map<String, dynamic> json) =>
    _StreamTransport(
      server: json['server'] as String? ?? '',
      serverName: json['server_name'] as String? ?? '',
      spkiPins:
          (json['spki_sha256'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      psk: json['psk'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
    );

Map<String, dynamic> _$StreamTransportToJson(_StreamTransport instance) =>
    <String, dynamic>{
      'server': instance.server,
      'server_name': instance.serverName,
      'spki_sha256': instance.spkiPins,
      'psk': instance.psk,
      'client_id': instance.clientId,
    };

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
  obfuscation: json['obfuscation'] == null
      ? null
      : Obfuscation.fromJson(json['obfuscation'] as Map<String, dynamic>),
  stream: json['stream'] == null
      ? null
      : StreamTransport.fromJson(json['stream'] as Map<String, dynamic>),
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
      'obfuscation': instance.obfuscation,
      'stream': instance.stream,
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
      obfuscation: json['obfuscation'] == null
          ? null
          : Obfuscation.fromJson(json['obfuscation'] as Map<String, dynamic>),
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
      'obfuscation': instance.obfuscation,
    };

_ServerStatus _$ServerStatusFromJson(Map<String, dynamic> json) =>
    _ServerStatus(
      serverId: json['server_id'] as String,
      name: json['name'] as String? ?? '',
      status: ServerHealth.fromWire(json['status'] as String?),
      activePeers: (json['active_peers'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$ServerStatusToJson(_ServerStatus instance) =>
    <String, dynamic>{
      'server_id': instance.serverId,
      'name': instance.name,
      'status': _serverHealthToWire(instance.status),
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
