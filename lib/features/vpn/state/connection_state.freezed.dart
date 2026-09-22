// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'connection_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ConnState {

 ConnPhase get phase; String get message; DialParams? get dial; String? get regionId; String? get serverId; bool get explicitTarget; DeviceStatus? get deviceStatus; DateTime? get lastStatusAt;/// Consecutive transient status-poll failures (network/timeout only).
/// Reset on any successful poll or fresh tunnel start.
 int get pollFailures;/// Last observed native tunnel stage (null until first observation).
 VpnStage? get lastStage;/// Last published traffic counters for the Home card (null until the
/// first successful `trafficStats()` read with a usable counter, or
/// when the plugin reports none).
 int? get rxBytes; int? get txBytes;/// Degraded-tunnel banner (backend unreachable or stage anomaly).
/// Null when healthy.
 String? get healthNote;/// Structured cause of the last backend interaction failure while
/// connected, if any (null when healthy). [healthNote] carries the
/// human-facing text; this carries the machine-readable distinction the
/// UI uses to separate "authentication expired" from "network
/// unreachable" (see `domain/backend_issue.dart`).
 BackendIssue? get backendIssue;/// True when the last explicit user operation (switch / Quick Connect)
/// failed. Set by the shared failure surfacing and cleared when a new
/// operation starts, so the UI can decide whether [message] warrants a
/// snack without parsing its (localizable, controller-owned) wording.
 bool get opFailed;/// Auto-heal restarts for this connected session. Retries on every
/// corroborated stall (the health-tick cadence is the backoff), so a
/// flaky tunnel recovers without user action — until the move budget is
/// spent and the trailing retries are used up, at which point recovery
/// surfaces an actionable error. Same reset points as
/// [autoFailoverAttempts].
 int get autoHealAttempts;/// Automatic dead-server moves for this connected session. Incremented
/// on failover once the same-server heal is spent; capped by the
/// controller's max so two dead servers can't ping-pong forever.
/// Reset on manual connect/switch, disconnect, and a successful status
/// poll that lands on a *healthy* tunnel path (an observed, fresh
/// handshake): an out-of-band poll success while the WireGuard path stays
/// dead is not the outage ending, so it must not restore the ladder.
 int get autoFailoverAttempts;
/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnStateCopyWith<ConnState> get copyWith => _$ConnStateCopyWithImpl<ConnState>(this as ConnState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ConnState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnState&&(identical(other.phase, _this.phase) || other.phase == _this.phase)&&(identical(other.message, _this.message) || other.message == _this.message)&&(identical(other.dial, _this.dial) || other.dial == _this.dial)&&(identical(other.regionId, _this.regionId) || other.regionId == _this.regionId)&&(identical(other.serverId, _this.serverId) || other.serverId == _this.serverId)&&(identical(other.explicitTarget, _this.explicitTarget) || other.explicitTarget == _this.explicitTarget)&&(identical(other.deviceStatus, _this.deviceStatus) || other.deviceStatus == _this.deviceStatus)&&(identical(other.lastStatusAt, _this.lastStatusAt) || other.lastStatusAt == _this.lastStatusAt)&&(identical(other.pollFailures, _this.pollFailures) || other.pollFailures == _this.pollFailures)&&(identical(other.lastStage, _this.lastStage) || other.lastStage == _this.lastStage)&&(identical(other.rxBytes, _this.rxBytes) || other.rxBytes == _this.rxBytes)&&(identical(other.txBytes, _this.txBytes) || other.txBytes == _this.txBytes)&&(identical(other.healthNote, _this.healthNote) || other.healthNote == _this.healthNote)&&(identical(other.backendIssue, _this.backendIssue) || other.backendIssue == _this.backendIssue)&&(identical(other.opFailed, _this.opFailed) || other.opFailed == _this.opFailed)&&(identical(other.autoHealAttempts, _this.autoHealAttempts) || other.autoHealAttempts == _this.autoHealAttempts)&&(identical(other.autoFailoverAttempts, _this.autoFailoverAttempts) || other.autoFailoverAttempts == _this.autoFailoverAttempts));
}


@override
int get hashCode {
  final _this = this as ConnState;
  return Object.hash(runtimeType,_this.phase,_this.message,_this.dial,_this.regionId,_this.serverId,_this.explicitTarget,_this.deviceStatus,_this.lastStatusAt,_this.pollFailures,_this.lastStage,_this.rxBytes,_this.txBytes,_this.healthNote,_this.backendIssue,_this.opFailed,_this.autoHealAttempts,_this.autoFailoverAttempts);
}

@override
String toString() {
  final _this = this as ConnState;
  return 'ConnState(phase: ${_this.phase}, message: ${_this.message}, dial: ${_this.dial}, regionId: ${_this.regionId}, serverId: ${_this.serverId}, explicitTarget: ${_this.explicitTarget}, deviceStatus: ${_this.deviceStatus}, lastStatusAt: ${_this.lastStatusAt}, pollFailures: ${_this.pollFailures}, lastStage: ${_this.lastStage}, rxBytes: ${_this.rxBytes}, txBytes: ${_this.txBytes}, healthNote: ${_this.healthNote}, backendIssue: ${_this.backendIssue}, opFailed: ${_this.opFailed}, autoHealAttempts: ${_this.autoHealAttempts}, autoFailoverAttempts: ${_this.autoFailoverAttempts})';
}


}

/// @nodoc
abstract mixin class $ConnStateCopyWith<$Res>  {
  factory $ConnStateCopyWith(ConnState value, $Res Function(ConnState) _then) = _$ConnStateCopyWithImpl;
@useResult
$Res call({
 ConnPhase phase, String message, DialParams? dial, String? regionId, String? serverId, bool explicitTarget, DeviceStatus? deviceStatus, DateTime? lastStatusAt, int pollFailures, VpnStage? lastStage, int? rxBytes, int? txBytes, String? healthNote, BackendIssue? backendIssue, bool opFailed, int autoHealAttempts, int autoFailoverAttempts
});


$DialParamsCopyWith<$Res>? get dial;$DeviceStatusCopyWith<$Res>? get deviceStatus;

}
/// @nodoc
class _$ConnStateCopyWithImpl<$Res>
    implements $ConnStateCopyWith<$Res> {
  _$ConnStateCopyWithImpl(this._self, this._then);

  final ConnState _self;
  final $Res Function(ConnState) _then;

/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? phase = null,Object? message = null,Object? dial = freezed,Object? regionId = freezed,Object? serverId = freezed,Object? explicitTarget = null,Object? deviceStatus = freezed,Object? lastStatusAt = freezed,Object? pollFailures = null,Object? lastStage = freezed,Object? rxBytes = freezed,Object? txBytes = freezed,Object? healthNote = freezed,Object? backendIssue = freezed,Object? opFailed = null,Object? autoHealAttempts = null,Object? autoFailoverAttempts = null,}) {
  return _then(ConnState(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as ConnPhase,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,dial: freezed == dial ? _self.dial : dial // ignore: cast_nullable_to_non_nullable
as DialParams?,regionId: freezed == regionId ? _self.regionId : regionId // ignore: cast_nullable_to_non_nullable
as String?,serverId: freezed == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String?,explicitTarget: null == explicitTarget ? _self.explicitTarget : explicitTarget // ignore: cast_nullable_to_non_nullable
as bool,deviceStatus: freezed == deviceStatus ? _self.deviceStatus : deviceStatus // ignore: cast_nullable_to_non_nullable
as DeviceStatus?,lastStatusAt: freezed == lastStatusAt ? _self.lastStatusAt : lastStatusAt // ignore: cast_nullable_to_non_nullable
as DateTime?,pollFailures: null == pollFailures ? _self.pollFailures : pollFailures // ignore: cast_nullable_to_non_nullable
as int,lastStage: freezed == lastStage ? _self.lastStage : lastStage // ignore: cast_nullable_to_non_nullable
as VpnStage?,rxBytes: freezed == rxBytes ? _self.rxBytes : rxBytes // ignore: cast_nullable_to_non_nullable
as int?,txBytes: freezed == txBytes ? _self.txBytes : txBytes // ignore: cast_nullable_to_non_nullable
as int?,healthNote: freezed == healthNote ? _self.healthNote : healthNote // ignore: cast_nullable_to_non_nullable
as String?,backendIssue: freezed == backendIssue ? _self.backendIssue : backendIssue // ignore: cast_nullable_to_non_nullable
as BackendIssue?,opFailed: null == opFailed ? _self.opFailed : opFailed // ignore: cast_nullable_to_non_nullable
as bool,autoHealAttempts: null == autoHealAttempts ? _self.autoHealAttempts : autoHealAttempts // ignore: cast_nullable_to_non_nullable
as int,autoFailoverAttempts: null == autoFailoverAttempts ? _self.autoFailoverAttempts : autoFailoverAttempts // ignore: cast_nullable_to_non_nullable
as int,
  ));
}
/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DialParamsCopyWith<$Res>? get dial {
    if (_self.dial == null) {
    return null;
  }

  return $DialParamsCopyWith<$Res>(_self.dial!, (value) {
    return _then(_self.copyWith(dial: value));
  });
}/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DeviceStatusCopyWith<$Res>? get deviceStatus {
    if (_self.deviceStatus == null) {
    return null;
  }

  return $DeviceStatusCopyWith<$Res>(_self.deviceStatus!, (value) {
    return _then(_self.copyWith(deviceStatus: value));
  });
}
}


/// Adds pattern-matching-related methods to [ConnState].
extension ConnStatePatterns on ConnState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ConnState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ConnState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ConnState value)  $default,){
final _that = this;
switch (_that) {
case _ConnState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ConnState value)?  $default,){
final _that = this;
switch (_that) {
case _ConnState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ConnPhase phase,  String message,  DialParams? dial,  String? regionId,  String? serverId,  bool explicitTarget,  DeviceStatus? deviceStatus,  DateTime? lastStatusAt,  int pollFailures,  VpnStage? lastStage,  int? rxBytes,  int? txBytes,  String? healthNote,  BackendIssue? backendIssue,  bool opFailed,  int autoHealAttempts,  int autoFailoverAttempts)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ConnState() when $default != null:
return $default(_that.phase,_that.message,_that.dial,_that.regionId,_that.serverId,_that.explicitTarget,_that.deviceStatus,_that.lastStatusAt,_that.pollFailures,_that.lastStage,_that.rxBytes,_that.txBytes,_that.healthNote,_that.backendIssue,_that.opFailed,_that.autoHealAttempts,_that.autoFailoverAttempts);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ConnPhase phase,  String message,  DialParams? dial,  String? regionId,  String? serverId,  bool explicitTarget,  DeviceStatus? deviceStatus,  DateTime? lastStatusAt,  int pollFailures,  VpnStage? lastStage,  int? rxBytes,  int? txBytes,  String? healthNote,  BackendIssue? backendIssue,  bool opFailed,  int autoHealAttempts,  int autoFailoverAttempts)  $default,) {final _that = this;
switch (_that) {
case _ConnState():
return $default(_that.phase,_that.message,_that.dial,_that.regionId,_that.serverId,_that.explicitTarget,_that.deviceStatus,_that.lastStatusAt,_that.pollFailures,_that.lastStage,_that.rxBytes,_that.txBytes,_that.healthNote,_that.backendIssue,_that.opFailed,_that.autoHealAttempts,_that.autoFailoverAttempts);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ConnPhase phase,  String message,  DialParams? dial,  String? regionId,  String? serverId,  bool explicitTarget,  DeviceStatus? deviceStatus,  DateTime? lastStatusAt,  int pollFailures,  VpnStage? lastStage,  int? rxBytes,  int? txBytes,  String? healthNote,  BackendIssue? backendIssue,  bool opFailed,  int autoHealAttempts,  int autoFailoverAttempts)?  $default,) {final _that = this;
switch (_that) {
case _ConnState() when $default != null:
return $default(_that.phase,_that.message,_that.dial,_that.regionId,_that.serverId,_that.explicitTarget,_that.deviceStatus,_that.lastStatusAt,_that.pollFailures,_that.lastStage,_that.rxBytes,_that.txBytes,_that.healthNote,_that.backendIssue,_that.opFailed,_that.autoHealAttempts,_that.autoFailoverAttempts);case _:
  return null;

}
}

}

/// @nodoc


class _ConnState implements ConnState {
  const _ConnState({this.phase = ConnPhase.idle, this.message = '', this.dial, this.regionId, this.serverId, this.explicitTarget = false, this.deviceStatus, this.lastStatusAt, this.pollFailures = 0, this.lastStage, this.rxBytes, this.txBytes, this.healthNote, this.backendIssue, this.opFailed = false, this.autoHealAttempts = 0, this.autoFailoverAttempts = 0});


@override@JsonKey() final  ConnPhase phase;
@override@JsonKey() final  String message;
@override final  DialParams? dial;
@override final  String? regionId;
@override final  String? serverId;
@override@JsonKey() final  bool explicitTarget;
@override final  DeviceStatus? deviceStatus;
@override final  DateTime? lastStatusAt;
/// Consecutive transient status-poll failures (network/timeout only).
/// Reset on any successful poll or fresh tunnel start.
@override@JsonKey() final  int pollFailures;
/// Last observed native tunnel stage (null until first observation).
@override final  VpnStage? lastStage;
/// Last published traffic counters for the Home card (null until the
/// first successful `trafficStats()` read with a usable counter, or
/// when the plugin reports none).
@override final  int? rxBytes;
@override final  int? txBytes;
/// Degraded-tunnel banner (backend unreachable or stage anomaly).
/// Null when healthy.
@override final  String? healthNote;
/// Structured cause of the last backend interaction failure while
/// connected, if any (null when healthy). [healthNote] carries the
/// human-facing text; this carries the machine-readable distinction the
/// UI uses to separate "authentication expired" from "network
/// unreachable" (see `domain/backend_issue.dart`).
@override final  BackendIssue? backendIssue;
/// True when the last explicit user operation (switch / Quick Connect)
/// failed. Set by the shared failure surfacing and cleared when a new
/// operation starts, so the UI can decide whether [message] warrants a
/// snack without parsing its (localizable, controller-owned) wording.
@override@JsonKey() final  bool opFailed;
/// Auto-heal restarts for this connected session. Retries on every
/// corroborated stall (the health-tick cadence is the backoff), so a
/// flaky tunnel recovers without user action — until the move budget is
/// spent and the trailing retries are used up, at which point recovery
/// surfaces an actionable error. Same reset points as
/// [autoFailoverAttempts].
@override@JsonKey() final  int autoHealAttempts;
/// Automatic dead-server moves for this connected session. Incremented
/// on failover once the same-server heal is spent; capped by the
/// controller's max so two dead servers can't ping-pong forever.
/// Reset on manual connect/switch, disconnect, and a successful status
/// poll that lands on a *healthy* tunnel path (an observed, fresh
/// handshake): an out-of-band poll success while the WireGuard path stays
/// dead is not the outage ending, so it must not restore the ladder.
@override@JsonKey() final  int autoFailoverAttempts;

/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConnStateCopyWith<_ConnState> get copyWith => __$ConnStateCopyWithImpl<_ConnState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ConnState&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.message, message) || other.message == message)&&(identical(other.dial, dial) || other.dial == dial)&&(identical(other.regionId, regionId) || other.regionId == regionId)&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.explicitTarget, explicitTarget) || other.explicitTarget == explicitTarget)&&(identical(other.deviceStatus, deviceStatus) || other.deviceStatus == deviceStatus)&&(identical(other.lastStatusAt, lastStatusAt) || other.lastStatusAt == lastStatusAt)&&(identical(other.pollFailures, pollFailures) || other.pollFailures == pollFailures)&&(identical(other.lastStage, lastStage) || other.lastStage == lastStage)&&(identical(other.rxBytes, rxBytes) || other.rxBytes == rxBytes)&&(identical(other.txBytes, txBytes) || other.txBytes == txBytes)&&(identical(other.healthNote, healthNote) || other.healthNote == healthNote)&&(identical(other.backendIssue, backendIssue) || other.backendIssue == backendIssue)&&(identical(other.opFailed, opFailed) || other.opFailed == opFailed)&&(identical(other.autoHealAttempts, autoHealAttempts) || other.autoHealAttempts == autoHealAttempts)&&(identical(other.autoFailoverAttempts, autoFailoverAttempts) || other.autoFailoverAttempts == autoFailoverAttempts));
}


@override
int get hashCode {
    return Object.hash(runtimeType,phase,message,dial,regionId,serverId,explicitTarget,deviceStatus,lastStatusAt,pollFailures,lastStage,rxBytes,txBytes,healthNote,backendIssue,opFailed,autoHealAttempts,autoFailoverAttempts);
}

@override
String toString() {
    return 'ConnState(phase: $phase, message: $message, dial: $dial, regionId: $regionId, serverId: $serverId, explicitTarget: $explicitTarget, deviceStatus: $deviceStatus, lastStatusAt: $lastStatusAt, pollFailures: $pollFailures, lastStage: $lastStage, rxBytes: $rxBytes, txBytes: $txBytes, healthNote: $healthNote, backendIssue: $backendIssue, opFailed: $opFailed, autoHealAttempts: $autoHealAttempts, autoFailoverAttempts: $autoFailoverAttempts)';
}


}

/// @nodoc
abstract mixin class _$ConnStateCopyWith<$Res> implements $ConnStateCopyWith<$Res> {
  factory _$ConnStateCopyWith(_ConnState value, $Res Function(_ConnState) _then) = __$ConnStateCopyWithImpl;
@override @useResult
$Res call({
 ConnPhase phase, String message, DialParams? dial, String? regionId, String? serverId, bool explicitTarget, DeviceStatus? deviceStatus, DateTime? lastStatusAt, int pollFailures, VpnStage? lastStage, int? rxBytes, int? txBytes, String? healthNote, BackendIssue? backendIssue, bool opFailed, int autoHealAttempts, int autoFailoverAttempts
});


@override $DialParamsCopyWith<$Res>? get dial;@override $DeviceStatusCopyWith<$Res>? get deviceStatus;

}
/// @nodoc
class __$ConnStateCopyWithImpl<$Res>
    implements _$ConnStateCopyWith<$Res> {
  __$ConnStateCopyWithImpl(this._self, this._then);

  final _ConnState _self;
  final $Res Function(_ConnState) _then;

/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? phase = null,Object? message = null,Object? dial = freezed,Object? regionId = freezed,Object? serverId = freezed,Object? explicitTarget = null,Object? deviceStatus = freezed,Object? lastStatusAt = freezed,Object? pollFailures = null,Object? lastStage = freezed,Object? rxBytes = freezed,Object? txBytes = freezed,Object? healthNote = freezed,Object? backendIssue = freezed,Object? opFailed = null,Object? autoHealAttempts = null,Object? autoFailoverAttempts = null,}) {
  return _then(_ConnState(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as ConnPhase,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,dial: freezed == dial ? _self.dial : dial // ignore: cast_nullable_to_non_nullable
as DialParams?,regionId: freezed == regionId ? _self.regionId : regionId // ignore: cast_nullable_to_non_nullable
as String?,serverId: freezed == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String?,explicitTarget: null == explicitTarget ? _self.explicitTarget : explicitTarget // ignore: cast_nullable_to_non_nullable
as bool,deviceStatus: freezed == deviceStatus ? _self.deviceStatus : deviceStatus // ignore: cast_nullable_to_non_nullable
as DeviceStatus?,lastStatusAt: freezed == lastStatusAt ? _self.lastStatusAt : lastStatusAt // ignore: cast_nullable_to_non_nullable
as DateTime?,pollFailures: null == pollFailures ? _self.pollFailures : pollFailures // ignore: cast_nullable_to_non_nullable
as int,lastStage: freezed == lastStage ? _self.lastStage : lastStage // ignore: cast_nullable_to_non_nullable
as VpnStage?,rxBytes: freezed == rxBytes ? _self.rxBytes : rxBytes // ignore: cast_nullable_to_non_nullable
as int?,txBytes: freezed == txBytes ? _self.txBytes : txBytes // ignore: cast_nullable_to_non_nullable
as int?,healthNote: freezed == healthNote ? _self.healthNote : healthNote // ignore: cast_nullable_to_non_nullable
as String?,backendIssue: freezed == backendIssue ? _self.backendIssue : backendIssue // ignore: cast_nullable_to_non_nullable
as BackendIssue?,opFailed: null == opFailed ? _self.opFailed : opFailed // ignore: cast_nullable_to_non_nullable
as bool,autoHealAttempts: null == autoHealAttempts ? _self.autoHealAttempts : autoHealAttempts // ignore: cast_nullable_to_non_nullable
as int,autoFailoverAttempts: null == autoFailoverAttempts ? _self.autoFailoverAttempts : autoFailoverAttempts // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DialParamsCopyWith<$Res>? get dial {
    if (_self.dial == null) {
    return null;
  }

  return $DialParamsCopyWith<$Res>(_self.dial!, (value) {
    return _then(_self.copyWith(dial: value));
  });
}/// Create a copy of ConnState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DeviceStatusCopyWith<$Res>? get deviceStatus {
    if (_self.deviceStatus == null) {
    return null;
  }

  return $DeviceStatusCopyWith<$Res>(_self.deviceStatus!, (value) {
    return _then(_self.copyWith(deviceStatus: value));
  });
}
}

// dart format on
