// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$DialParams {

@JsonKey(name: 'id') String get deviceId;@JsonKey(name: 'assigned_ip') String get assignedIp;@JsonKey(name: 'server_id') String get serverId;@JsonKey(name: 'server_name') String get serverName; String get endpoint;@JsonKey(name: 'wg_port') int get wgPort;@JsonKey(name: 'wg_dns') String get wgDns;@JsonKey(name: 'wg_public_key') String get wgPublicKey;@JsonKey(name: 'client_public_key') String? get clientPublicKey;
/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DialParamsCopyWith<DialParams> get copyWith => _$DialParamsCopyWithImpl<DialParams>(this as DialParams, _$identity);

  /// Serializes this DialParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as DialParams;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DialParams&&(identical(other.deviceId, _this.deviceId) || other.deviceId == _this.deviceId)&&(identical(other.assignedIp, _this.assignedIp) || other.assignedIp == _this.assignedIp)&&(identical(other.serverId, _this.serverId) || other.serverId == _this.serverId)&&(identical(other.serverName, _this.serverName) || other.serverName == _this.serverName)&&(identical(other.endpoint, _this.endpoint) || other.endpoint == _this.endpoint)&&(identical(other.wgPort, _this.wgPort) || other.wgPort == _this.wgPort)&&(identical(other.wgDns, _this.wgDns) || other.wgDns == _this.wgDns)&&(identical(other.wgPublicKey, _this.wgPublicKey) || other.wgPublicKey == _this.wgPublicKey)&&(identical(other.clientPublicKey, _this.clientPublicKey) || other.clientPublicKey == _this.clientPublicKey));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as DialParams;
  return Object.hash(runtimeType,_this.deviceId,_this.assignedIp,_this.serverId,_this.serverName,_this.endpoint,_this.wgPort,_this.wgDns,_this.wgPublicKey,_this.clientPublicKey);
}

@override
String toString() {
  final _this = this as DialParams;
  return 'DialParams(deviceId: ${_this.deviceId}, assignedIp: ${_this.assignedIp}, serverId: ${_this.serverId}, serverName: ${_this.serverName}, endpoint: ${_this.endpoint}, wgPort: ${_this.wgPort}, wgDns: ${_this.wgDns}, wgPublicKey: ${_this.wgPublicKey}, clientPublicKey: ${_this.clientPublicKey})';
}


}

/// @nodoc
abstract mixin class $DialParamsCopyWith<$Res>  {
  factory $DialParamsCopyWith(DialParams value, $Res Function(DialParams) _then) = _$DialParamsCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'id') String deviceId,@JsonKey(name: 'assigned_ip') String assignedIp,@JsonKey(name: 'server_id') String serverId,@JsonKey(name: 'server_name') String serverName, String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String wgPublicKey,@JsonKey(name: 'client_public_key') String? clientPublicKey
});




}
/// @nodoc
class _$DialParamsCopyWithImpl<$Res>
    implements $DialParamsCopyWith<$Res> {
  _$DialParamsCopyWithImpl(this._self, this._then);

  final DialParams _self;
  final $Res Function(DialParams) _then;

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? deviceId = null,Object? assignedIp = null,Object? serverId = null,Object? serverName = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = null,Object? clientPublicKey = freezed,}) {
  return _then(DialParams(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,assignedIp: null == assignedIp ? _self.assignedIp : assignedIp // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: null == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String,clientPublicKey: freezed == clientPublicKey ? _self.clientPublicKey : clientPublicKey // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [DialParams].
extension DialParamsPatterns on DialParams {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DialParams value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DialParams value)  $default,){
final _that = this;
switch (_that) {
case _DialParams():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DialParams value)?  $default,){
final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey)  $default,) {final _that = this;
switch (_that) {
case _DialParams():
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey)?  $default,) {final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DialParams implements DialParams {
  const _DialParams({@JsonKey(name: 'id') required this.deviceId, @JsonKey(name: 'assigned_ip') required this.assignedIp, @JsonKey(name: 'server_id') required this.serverId, @JsonKey(name: 'server_name') this.serverName = '', required this.endpoint, @JsonKey(name: 'wg_port') required this.wgPort, @JsonKey(name: 'wg_dns') required this.wgDns, @JsonKey(name: 'wg_public_key') required this.wgPublicKey, @JsonKey(name: 'client_public_key') this.clientPublicKey});
  factory _DialParams.fromJson(Map<String, dynamic> json) => _$DialParamsFromJson(json);

@override@JsonKey(name: 'id') final  String deviceId;
@override@JsonKey(name: 'assigned_ip') final  String assignedIp;
@override@JsonKey(name: 'server_id') final  String serverId;
@override@JsonKey(name: 'server_name') final  String serverName;
@override final  String endpoint;
@override@JsonKey(name: 'wg_port') final  int wgPort;
@override@JsonKey(name: 'wg_dns') final  String wgDns;
@override@JsonKey(name: 'wg_public_key') final  String wgPublicKey;
@override@JsonKey(name: 'client_public_key') final  String? clientPublicKey;

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DialParamsCopyWith<_DialParams> get copyWith => __$DialParamsCopyWithImpl<_DialParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DialParamsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DialParams&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.assignedIp, assignedIp) || other.assignedIp == assignedIp)&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.serverName, serverName) || other.serverName == serverName)&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.wgPort, wgPort) || other.wgPort == wgPort)&&(identical(other.wgDns, wgDns) || other.wgDns == wgDns)&&(identical(other.wgPublicKey, wgPublicKey) || other.wgPublicKey == wgPublicKey)&&(identical(other.clientPublicKey, clientPublicKey) || other.clientPublicKey == clientPublicKey));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,deviceId,assignedIp,serverId,serverName,endpoint,wgPort,wgDns,wgPublicKey,clientPublicKey);
}

@override
String toString() {
    return 'DialParams(deviceId: $deviceId, assignedIp: $assignedIp, serverId: $serverId, serverName: $serverName, endpoint: $endpoint, wgPort: $wgPort, wgDns: $wgDns, wgPublicKey: $wgPublicKey, clientPublicKey: $clientPublicKey)';
}


}

/// @nodoc
abstract mixin class _$DialParamsCopyWith<$Res> implements $DialParamsCopyWith<$Res> {
  factory _$DialParamsCopyWith(_DialParams value, $Res Function(_DialParams) _then) = __$DialParamsCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'id') String deviceId,@JsonKey(name: 'assigned_ip') String assignedIp,@JsonKey(name: 'server_id') String serverId,@JsonKey(name: 'server_name') String serverName, String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String wgPublicKey,@JsonKey(name: 'client_public_key') String? clientPublicKey
});




}
/// @nodoc
class __$DialParamsCopyWithImpl<$Res>
    implements _$DialParamsCopyWith<$Res> {
  __$DialParamsCopyWithImpl(this._self, this._then);

  final _DialParams _self;
  final $Res Function(_DialParams) _then;

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? assignedIp = null,Object? serverId = null,Object? serverName = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = null,Object? clientPublicKey = freezed,}) {
  return _then(_DialParams(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,assignedIp: null == assignedIp ? _self.assignedIp : assignedIp // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: null == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String,clientPublicKey: freezed == clientPublicKey ? _self.clientPublicKey : clientPublicKey // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$DiscoveryServer {

 String get id; String get name;@JsonKey(readValue: _readDialHost) String get endpoint;@JsonKey(name: 'wg_port') int get wgPort;@JsonKey(name: 'wg_dns') String get wgDns;@JsonKey(name: 'wg_public_key') String? get wgPublicKey;@JsonKey(name: 'active_peers') int get activePeers;
/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DiscoveryServerCopyWith<DiscoveryServer> get copyWith => _$DiscoveryServerCopyWithImpl<DiscoveryServer>(this as DiscoveryServer, _$identity);

  /// Serializes this DiscoveryServer to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as DiscoveryServer;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DiscoveryServer&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.endpoint, _this.endpoint) || other.endpoint == _this.endpoint)&&(identical(other.wgPort, _this.wgPort) || other.wgPort == _this.wgPort)&&(identical(other.wgDns, _this.wgDns) || other.wgDns == _this.wgDns)&&(identical(other.wgPublicKey, _this.wgPublicKey) || other.wgPublicKey == _this.wgPublicKey)&&(identical(other.activePeers, _this.activePeers) || other.activePeers == _this.activePeers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as DiscoveryServer;
  return Object.hash(runtimeType,_this.id,_this.name,_this.endpoint,_this.wgPort,_this.wgDns,_this.wgPublicKey,_this.activePeers);
}

@override
String toString() {
  final _this = this as DiscoveryServer;
  return 'DiscoveryServer(id: ${_this.id}, name: ${_this.name}, endpoint: ${_this.endpoint}, wgPort: ${_this.wgPort}, wgDns: ${_this.wgDns}, wgPublicKey: ${_this.wgPublicKey}, activePeers: ${_this.activePeers})';
}


}

/// @nodoc
abstract mixin class $DiscoveryServerCopyWith<$Res>  {
  factory $DiscoveryServerCopyWith(DiscoveryServer value, $Res Function(DiscoveryServer) _then) = _$DiscoveryServerCopyWithImpl;
@useResult
$Res call({
 String id, String name,@JsonKey(readValue: _readDialHost) String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String? wgPublicKey,@JsonKey(name: 'active_peers') int activePeers
});




}
/// @nodoc
class _$DiscoveryServerCopyWithImpl<$Res>
    implements $DiscoveryServerCopyWith<$Res> {
  _$DiscoveryServerCopyWithImpl(this._self, this._then);

  final DiscoveryServer _self;
  final $Res Function(DiscoveryServer) _then;

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = freezed,Object? activePeers = null,}) {
  return _then(DiscoveryServer(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: freezed == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [DiscoveryServer].
extension DiscoveryServerPatterns on DiscoveryServer {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DiscoveryServer value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DiscoveryServer value)  $default,){
final _that = this;
switch (_that) {
case _DiscoveryServer():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DiscoveryServer value)?  $default,){
final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers)  $default,) {final _that = this;
switch (_that) {
case _DiscoveryServer():
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers)?  $default,) {final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DiscoveryServer extends DiscoveryServer {
  const _DiscoveryServer({required this.id, this.name = '', @JsonKey(readValue: _readDialHost) this.endpoint = '', @JsonKey(name: 'wg_port') required this.wgPort, @JsonKey(name: 'wg_dns') this.wgDns = '', @JsonKey(name: 'wg_public_key') this.wgPublicKey, @JsonKey(name: 'active_peers') this.activePeers = 0}): super._();
  factory _DiscoveryServer.fromJson(Map<String, dynamic> json) => _$DiscoveryServerFromJson(json);

@override final  String id;
@override@JsonKey() final  String name;
@override@JsonKey(readValue: _readDialHost) final  String endpoint;
@override@JsonKey(name: 'wg_port') final  int wgPort;
@override@JsonKey(name: 'wg_dns') final  String wgDns;
@override@JsonKey(name: 'wg_public_key') final  String? wgPublicKey;
@override@JsonKey(name: 'active_peers') final  int activePeers;

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DiscoveryServerCopyWith<_DiscoveryServer> get copyWith => __$DiscoveryServerCopyWithImpl<_DiscoveryServer>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DiscoveryServerToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DiscoveryServer&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.wgPort, wgPort) || other.wgPort == wgPort)&&(identical(other.wgDns, wgDns) || other.wgDns == wgDns)&&(identical(other.wgPublicKey, wgPublicKey) || other.wgPublicKey == wgPublicKey)&&(identical(other.activePeers, activePeers) || other.activePeers == activePeers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,endpoint,wgPort,wgDns,wgPublicKey,activePeers);
}

@override
String toString() {
    return 'DiscoveryServer(id: $id, name: $name, endpoint: $endpoint, wgPort: $wgPort, wgDns: $wgDns, wgPublicKey: $wgPublicKey, activePeers: $activePeers)';
}


}

/// @nodoc
abstract mixin class _$DiscoveryServerCopyWith<$Res> implements $DiscoveryServerCopyWith<$Res> {
  factory _$DiscoveryServerCopyWith(_DiscoveryServer value, $Res Function(_DiscoveryServer) _then) = __$DiscoveryServerCopyWithImpl;
@override @useResult
$Res call({
 String id, String name,@JsonKey(readValue: _readDialHost) String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String? wgPublicKey,@JsonKey(name: 'active_peers') int activePeers
});




}
/// @nodoc
class __$DiscoveryServerCopyWithImpl<$Res>
    implements _$DiscoveryServerCopyWith<$Res> {
  __$DiscoveryServerCopyWithImpl(this._self, this._then);

  final _DiscoveryServer _self;
  final $Res Function(_DiscoveryServer) _then;

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = freezed,Object? activePeers = null,}) {
  return _then(_DiscoveryServer(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: freezed == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$Region {

 String get id; String get name;@JsonKey(name: 'country_code') String? get countryCode; List<DiscoveryServer> get servers;
/// Create a copy of Region
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RegionCopyWith<Region> get copyWith => _$RegionCopyWithImpl<Region>(this as Region, _$identity);

  /// Serializes this Region to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as Region;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Region&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.countryCode, _this.countryCode) || other.countryCode == _this.countryCode)&&const DeepCollectionEquality().equals(other.servers, _this.servers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as Region;
  return Object.hash(runtimeType,_this.id,_this.name,_this.countryCode,const DeepCollectionEquality().hash(_this.servers));
}

@override
String toString() {
  final _this = this as Region;
  return 'Region(id: ${_this.id}, name: ${_this.name}, countryCode: ${_this.countryCode}, servers: ${_this.servers})';
}


}

/// @nodoc
abstract mixin class $RegionCopyWith<$Res>  {
  factory $RegionCopyWith(Region value, $Res Function(Region) _then) = _$RegionCopyWithImpl;
@useResult
$Res call({
 String id, String name,@JsonKey(name: 'country_code') String? countryCode, List<DiscoveryServer> servers
});




}
/// @nodoc
class _$RegionCopyWithImpl<$Res>
    implements $RegionCopyWith<$Res> {
  _$RegionCopyWithImpl(this._self, this._then);

  final Region _self;
  final $Res Function(Region) _then;

/// Create a copy of Region
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? countryCode = freezed,Object? servers = null,}) {
  return _then(Region(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,countryCode: freezed == countryCode ? _self.countryCode : countryCode // ignore: cast_nullable_to_non_nullable
as String?,servers: null == servers ? _self.servers : servers // ignore: cast_nullable_to_non_nullable
as List<DiscoveryServer>,
  ));
}

}


/// Adds pattern-matching-related methods to [Region].
extension RegionPatterns on Region {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Region value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Region() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Region value)  $default,){
final _that = this;
switch (_that) {
case _Region():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Region value)?  $default,){
final _that = this;
switch (_that) {
case _Region() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(name: 'country_code')  String? countryCode,  List<DiscoveryServer> servers)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Region() when $default != null:
return $default(_that.id,_that.name,_that.countryCode,_that.servers);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(name: 'country_code')  String? countryCode,  List<DiscoveryServer> servers)  $default,) {final _that = this;
switch (_that) {
case _Region():
return $default(_that.id,_that.name,_that.countryCode,_that.servers);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name, @JsonKey(name: 'country_code')  String? countryCode,  List<DiscoveryServer> servers)?  $default,) {final _that = this;
switch (_that) {
case _Region() when $default != null:
return $default(_that.id,_that.name,_that.countryCode,_that.servers);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Region extends Region {
  const _Region({required this.id, this.name = '', @JsonKey(name: 'country_code') this.countryCode,  List<DiscoveryServer> servers = const []}): _servers = servers,super._();
  factory _Region.fromJson(Map<String, dynamic> json) => _$RegionFromJson(json);

@override final  String id;
@override@JsonKey() final  String name;
@override@JsonKey(name: 'country_code') final  String? countryCode;
 final  List<DiscoveryServer> _servers;
@override@JsonKey() List<DiscoveryServer> get servers {
  if (_servers is EqualUnmodifiableListView) return _servers;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_servers);
}


/// Create a copy of Region
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RegionCopyWith<_Region> get copyWith => __$RegionCopyWithImpl<_Region>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RegionToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _Region&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.countryCode, countryCode) || other.countryCode == countryCode)&&const DeepCollectionEquality().equals(other.servers, _servers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,countryCode,const DeepCollectionEquality().hash(_servers));
}

@override
String toString() {
    return 'Region(id: $id, name: $name, countryCode: $countryCode, servers: $servers)';
}


}

/// @nodoc
abstract mixin class _$RegionCopyWith<$Res> implements $RegionCopyWith<$Res> {
  factory _$RegionCopyWith(_Region value, $Res Function(_Region) _then) = __$RegionCopyWithImpl;
@override @useResult
$Res call({
 String id, String name,@JsonKey(name: 'country_code') String? countryCode, List<DiscoveryServer> servers
});




}
/// @nodoc
class __$RegionCopyWithImpl<$Res>
    implements _$RegionCopyWith<$Res> {
  __$RegionCopyWithImpl(this._self, this._then);

  final _Region _self;
  final $Res Function(_Region) _then;

/// Create a copy of Region
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? countryCode = freezed,Object? servers = null,}) {
  return _then(_Region(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,countryCode: freezed == countryCode ? _self.countryCode : countryCode // ignore: cast_nullable_to_non_nullable
as String?,servers: null == servers ? _self._servers : servers // ignore: cast_nullable_to_non_nullable
as List<DiscoveryServer>,
  ));
}


}


/// @nodoc
mixin _$DeviceStatus {

@JsonKey(name: 'device_id') String get deviceId; String get status;@JsonKey(name: 'suspended_reason') String? get suspendedReason; String? get tier;@JsonKey(name: 'max_devices') int? get maxDevices;@JsonKey(name: 'active_devices') int get activeDevices;@JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry) DateTime? get subscriptionExpiresAt;
/// Create a copy of DeviceStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeviceStatusCopyWith<DeviceStatus> get copyWith => _$DeviceStatusCopyWithImpl<DeviceStatus>(this as DeviceStatus, _$identity);

  /// Serializes this DeviceStatus to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as DeviceStatus;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DeviceStatus&&(identical(other.deviceId, _this.deviceId) || other.deviceId == _this.deviceId)&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.suspendedReason, _this.suspendedReason) || other.suspendedReason == _this.suspendedReason)&&(identical(other.tier, _this.tier) || other.tier == _this.tier)&&(identical(other.maxDevices, _this.maxDevices) || other.maxDevices == _this.maxDevices)&&(identical(other.activeDevices, _this.activeDevices) || other.activeDevices == _this.activeDevices)&&(identical(other.subscriptionExpiresAt, _this.subscriptionExpiresAt) || other.subscriptionExpiresAt == _this.subscriptionExpiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as DeviceStatus;
  return Object.hash(runtimeType,_this.deviceId,_this.status,_this.suspendedReason,_this.tier,_this.maxDevices,_this.activeDevices,_this.subscriptionExpiresAt);
}

@override
String toString() {
  final _this = this as DeviceStatus;
  return 'DeviceStatus(deviceId: ${_this.deviceId}, status: ${_this.status}, suspendedReason: ${_this.suspendedReason}, tier: ${_this.tier}, maxDevices: ${_this.maxDevices}, activeDevices: ${_this.activeDevices}, subscriptionExpiresAt: ${_this.subscriptionExpiresAt})';
}


}

/// @nodoc
abstract mixin class $DeviceStatusCopyWith<$Res>  {
  factory $DeviceStatusCopyWith(DeviceStatus value, $Res Function(DeviceStatus) _then) = _$DeviceStatusCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'device_id') String deviceId, String status,@JsonKey(name: 'suspended_reason') String? suspendedReason, String? tier,@JsonKey(name: 'max_devices') int? maxDevices,@JsonKey(name: 'active_devices') int activeDevices,@JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry) DateTime? subscriptionExpiresAt
});




}
/// @nodoc
class _$DeviceStatusCopyWithImpl<$Res>
    implements $DeviceStatusCopyWith<$Res> {
  _$DeviceStatusCopyWithImpl(this._self, this._then);

  final DeviceStatus _self;
  final $Res Function(DeviceStatus) _then;

/// Create a copy of DeviceStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? deviceId = null,Object? status = null,Object? suspendedReason = freezed,Object? tier = freezed,Object? maxDevices = freezed,Object? activeDevices = null,Object? subscriptionExpiresAt = freezed,}) {
  return _then(DeviceStatus(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,suspendedReason: freezed == suspendedReason ? _self.suspendedReason : suspendedReason // ignore: cast_nullable_to_non_nullable
as String?,tier: freezed == tier ? _self.tier : tier // ignore: cast_nullable_to_non_nullable
as String?,maxDevices: freezed == maxDevices ? _self.maxDevices : maxDevices // ignore: cast_nullable_to_non_nullable
as int?,activeDevices: null == activeDevices ? _self.activeDevices : activeDevices // ignore: cast_nullable_to_non_nullable
as int,subscriptionExpiresAt: freezed == subscriptionExpiresAt ? _self.subscriptionExpiresAt : subscriptionExpiresAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [DeviceStatus].
extension DeviceStatusPatterns on DeviceStatus {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DeviceStatus value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DeviceStatus() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DeviceStatus value)  $default,){
final _that = this;
switch (_that) {
case _DeviceStatus():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DeviceStatus value)?  $default,){
final _that = this;
switch (_that) {
case _DeviceStatus() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'device_id')  String deviceId,  String status, @JsonKey(name: 'suspended_reason')  String? suspendedReason,  String? tier, @JsonKey(name: 'max_devices')  int? maxDevices, @JsonKey(name: 'active_devices')  int activeDevices, @JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry)  DateTime? subscriptionExpiresAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DeviceStatus() when $default != null:
return $default(_that.deviceId,_that.status,_that.suspendedReason,_that.tier,_that.maxDevices,_that.activeDevices,_that.subscriptionExpiresAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'device_id')  String deviceId,  String status, @JsonKey(name: 'suspended_reason')  String? suspendedReason,  String? tier, @JsonKey(name: 'max_devices')  int? maxDevices, @JsonKey(name: 'active_devices')  int activeDevices, @JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry)  DateTime? subscriptionExpiresAt)  $default,) {final _that = this;
switch (_that) {
case _DeviceStatus():
return $default(_that.deviceId,_that.status,_that.suspendedReason,_that.tier,_that.maxDevices,_that.activeDevices,_that.subscriptionExpiresAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'device_id')  String deviceId,  String status, @JsonKey(name: 'suspended_reason')  String? suspendedReason,  String? tier, @JsonKey(name: 'max_devices')  int? maxDevices, @JsonKey(name: 'active_devices')  int activeDevices, @JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry)  DateTime? subscriptionExpiresAt)?  $default,) {final _that = this;
switch (_that) {
case _DeviceStatus() when $default != null:
return $default(_that.deviceId,_that.status,_that.suspendedReason,_that.tier,_that.maxDevices,_that.activeDevices,_that.subscriptionExpiresAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DeviceStatus extends DeviceStatus {
  const _DeviceStatus({@JsonKey(name: 'device_id') required this.deviceId, required this.status, @JsonKey(name: 'suspended_reason') this.suspendedReason, this.tier, @JsonKey(name: 'max_devices') this.maxDevices, @JsonKey(name: 'active_devices') this.activeDevices = 0, @JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry) this.subscriptionExpiresAt}): super._();
  factory _DeviceStatus.fromJson(Map<String, dynamic> json) => _$DeviceStatusFromJson(json);

@override@JsonKey(name: 'device_id') final  String deviceId;
@override final  String status;
@override@JsonKey(name: 'suspended_reason') final  String? suspendedReason;
@override final  String? tier;
@override@JsonKey(name: 'max_devices') final  int? maxDevices;
@override@JsonKey(name: 'active_devices') final  int activeDevices;
@override@JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry) final  DateTime? subscriptionExpiresAt;

/// Create a copy of DeviceStatus
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DeviceStatusCopyWith<_DeviceStatus> get copyWith => __$DeviceStatusCopyWithImpl<_DeviceStatus>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DeviceStatusToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DeviceStatus&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.status, status) || other.status == status)&&(identical(other.suspendedReason, suspendedReason) || other.suspendedReason == suspendedReason)&&(identical(other.tier, tier) || other.tier == tier)&&(identical(other.maxDevices, maxDevices) || other.maxDevices == maxDevices)&&(identical(other.activeDevices, activeDevices) || other.activeDevices == activeDevices)&&(identical(other.subscriptionExpiresAt, subscriptionExpiresAt) || other.subscriptionExpiresAt == subscriptionExpiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,deviceId,status,suspendedReason,tier,maxDevices,activeDevices,subscriptionExpiresAt);
}

@override
String toString() {
    return 'DeviceStatus(deviceId: $deviceId, status: $status, suspendedReason: $suspendedReason, tier: $tier, maxDevices: $maxDevices, activeDevices: $activeDevices, subscriptionExpiresAt: $subscriptionExpiresAt)';
}


}

/// @nodoc
abstract mixin class _$DeviceStatusCopyWith<$Res> implements $DeviceStatusCopyWith<$Res> {
  factory _$DeviceStatusCopyWith(_DeviceStatus value, $Res Function(_DeviceStatus) _then) = __$DeviceStatusCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'device_id') String deviceId, String status,@JsonKey(name: 'suspended_reason') String? suspendedReason, String? tier,@JsonKey(name: 'max_devices') int? maxDevices,@JsonKey(name: 'active_devices') int activeDevices,@JsonKey(name: 'subscription_expires_at', fromJson: _parseExpiry) DateTime? subscriptionExpiresAt
});




}
/// @nodoc
class __$DeviceStatusCopyWithImpl<$Res>
    implements _$DeviceStatusCopyWith<$Res> {
  __$DeviceStatusCopyWithImpl(this._self, this._then);

  final _DeviceStatus _self;
  final $Res Function(_DeviceStatus) _then;

/// Create a copy of DeviceStatus
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? status = null,Object? suspendedReason = freezed,Object? tier = freezed,Object? maxDevices = freezed,Object? activeDevices = null,Object? subscriptionExpiresAt = freezed,}) {
  return _then(_DeviceStatus(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,suspendedReason: freezed == suspendedReason ? _self.suspendedReason : suspendedReason // ignore: cast_nullable_to_non_nullable
as String?,tier: freezed == tier ? _self.tier : tier // ignore: cast_nullable_to_non_nullable
as String?,maxDevices: freezed == maxDevices ? _self.maxDevices : maxDevices // ignore: cast_nullable_to_non_nullable
as int?,activeDevices: null == activeDevices ? _self.activeDevices : activeDevices // ignore: cast_nullable_to_non_nullable
as int,subscriptionExpiresAt: freezed == subscriptionExpiresAt ? _self.subscriptionExpiresAt : subscriptionExpiresAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
