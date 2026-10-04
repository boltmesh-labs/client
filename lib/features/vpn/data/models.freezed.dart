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
mixin _$Obfuscation {

 String get mode; ObfuscationParams? get params;
/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObfuscationCopyWith<Obfuscation> get copyWith => _$ObfuscationCopyWithImpl<Obfuscation>(this as Obfuscation, _$identity);

  /// Serializes this Obfuscation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as Obfuscation;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Obfuscation&&(identical(other.mode, _this.mode) || other.mode == _this.mode)&&(identical(other.params, _this.params) || other.params == _this.params));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as Obfuscation;
  return Object.hash(runtimeType,_this.mode,_this.params);
}

@override
String toString() {
  final _this = this as Obfuscation;
  return 'Obfuscation(mode: ${_this.mode}, params: ${_this.params})';
}


}

/// @nodoc
abstract mixin class $ObfuscationCopyWith<$Res>  {
  factory $ObfuscationCopyWith(Obfuscation value, $Res Function(Obfuscation) _then) = _$ObfuscationCopyWithImpl;
@useResult
$Res call({
 String mode, ObfuscationParams? params
});


$ObfuscationParamsCopyWith<$Res>? get params;

}
/// @nodoc
class _$ObfuscationCopyWithImpl<$Res>
    implements $ObfuscationCopyWith<$Res> {
  _$ObfuscationCopyWithImpl(this._self, this._then);

  final Obfuscation _self;
  final $Res Function(Obfuscation) _then;

/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? mode = null,Object? params = freezed,}) {
  return _then(Obfuscation(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as String,params: freezed == params ? _self.params : params // ignore: cast_nullable_to_non_nullable
as ObfuscationParams?,
  ));
}
/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationParamsCopyWith<$Res>? get params {
    if (_self.params == null) {
    return null;
  }

  return $ObfuscationParamsCopyWith<$Res>(_self.params!, (value) {
    return _then(_self.copyWith(params: value));
  });
}
}


/// Adds pattern-matching-related methods to [Obfuscation].
extension ObfuscationPatterns on Obfuscation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Obfuscation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Obfuscation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Obfuscation value)  $default,){
final _that = this;
switch (_that) {
case _Obfuscation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Obfuscation value)?  $default,){
final _that = this;
switch (_that) {
case _Obfuscation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String mode,  ObfuscationParams? params)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Obfuscation() when $default != null:
return $default(_that.mode,_that.params);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String mode,  ObfuscationParams? params)  $default,) {final _that = this;
switch (_that) {
case _Obfuscation():
return $default(_that.mode,_that.params);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String mode,  ObfuscationParams? params)?  $default,) {final _that = this;
switch (_that) {
case _Obfuscation() when $default != null:
return $default(_that.mode,_that.params);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Obfuscation extends Obfuscation {
  const _Obfuscation({this.mode = '', this.params}): super._();
  factory _Obfuscation.fromJson(Map<String, dynamic> json) => _$ObfuscationFromJson(json);

@override@JsonKey() final  String mode;
@override final  ObfuscationParams? params;

/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObfuscationCopyWith<_Obfuscation> get copyWith => __$ObfuscationCopyWithImpl<_Obfuscation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ObfuscationToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _Obfuscation&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.params, params) || other.params == params));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,mode,params);
}

@override
String toString() {
    return 'Obfuscation(mode: $mode, params: $params)';
}


}

/// @nodoc
abstract mixin class _$ObfuscationCopyWith<$Res> implements $ObfuscationCopyWith<$Res> {
  factory _$ObfuscationCopyWith(_Obfuscation value, $Res Function(_Obfuscation) _then) = __$ObfuscationCopyWithImpl;
@override @useResult
$Res call({
 String mode, ObfuscationParams? params
});


@override $ObfuscationParamsCopyWith<$Res>? get params;

}
/// @nodoc
class __$ObfuscationCopyWithImpl<$Res>
    implements _$ObfuscationCopyWith<$Res> {
  __$ObfuscationCopyWithImpl(this._self, this._then);

  final _Obfuscation _self;
  final $Res Function(_Obfuscation) _then;

/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? mode = null,Object? params = freezed,}) {
  return _then(_Obfuscation(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as String,params: freezed == params ? _self.params : params // ignore: cast_nullable_to_non_nullable
as ObfuscationParams?,
  ));
}

/// Create a copy of Obfuscation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationParamsCopyWith<$Res>? get params {
    if (_self.params == null) {
    return null;
  }

  return $ObfuscationParamsCopyWith<$Res>(_self.params!, (value) {
    return _then(_self.copyWith(params: value));
  });
}
}


/// @nodoc
mixin _$ObfuscationParams {

@JsonKey(name: 'jc') int? get jc;@JsonKey(name: 'jmin') int? get jmin;@JsonKey(name: 'jmax') int? get jmax;@JsonKey(name: 's1') int? get s1;@JsonKey(name: 's2') int? get s2;@JsonKey(name: 's3') int? get s3;@JsonKey(name: 's4') int? get s4;@JsonKey(name: 'h1') List<int>? get h1;@JsonKey(name: 'h2') List<int>? get h2;@JsonKey(name: 'h3') List<int>? get h3;@JsonKey(name: 'h4') List<int>? get h4;
/// Create a copy of ObfuscationParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObfuscationParamsCopyWith<ObfuscationParams> get copyWith => _$ObfuscationParamsCopyWithImpl<ObfuscationParams>(this as ObfuscationParams, _$identity);

  /// Serializes this ObfuscationParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ObfuscationParams;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ObfuscationParams&&(identical(other.jc, _this.jc) || other.jc == _this.jc)&&(identical(other.jmin, _this.jmin) || other.jmin == _this.jmin)&&(identical(other.jmax, _this.jmax) || other.jmax == _this.jmax)&&(identical(other.s1, _this.s1) || other.s1 == _this.s1)&&(identical(other.s2, _this.s2) || other.s2 == _this.s2)&&(identical(other.s3, _this.s3) || other.s3 == _this.s3)&&(identical(other.s4, _this.s4) || other.s4 == _this.s4)&&const DeepCollectionEquality().equals(other.h1, _this.h1)&&const DeepCollectionEquality().equals(other.h2, _this.h2)&&const DeepCollectionEquality().equals(other.h3, _this.h3)&&const DeepCollectionEquality().equals(other.h4, _this.h4));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ObfuscationParams;
  return Object.hash(runtimeType,_this.jc,_this.jmin,_this.jmax,_this.s1,_this.s2,_this.s3,_this.s4,const DeepCollectionEquality().hash(_this.h1),const DeepCollectionEquality().hash(_this.h2),const DeepCollectionEquality().hash(_this.h3),const DeepCollectionEquality().hash(_this.h4));
}

@override
String toString() {
  final _this = this as ObfuscationParams;
  return 'ObfuscationParams(jc: ${_this.jc}, jmin: ${_this.jmin}, jmax: ${_this.jmax}, s1: ${_this.s1}, s2: ${_this.s2}, s3: ${_this.s3}, s4: ${_this.s4}, h1: ${_this.h1}, h2: ${_this.h2}, h3: ${_this.h3}, h4: ${_this.h4})';
}


}

/// @nodoc
abstract mixin class $ObfuscationParamsCopyWith<$Res>  {
  factory $ObfuscationParamsCopyWith(ObfuscationParams value, $Res Function(ObfuscationParams) _then) = _$ObfuscationParamsCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'jc') int? jc,@JsonKey(name: 'jmin') int? jmin,@JsonKey(name: 'jmax') int? jmax,@JsonKey(name: 's1') int? s1,@JsonKey(name: 's2') int? s2,@JsonKey(name: 's3') int? s3,@JsonKey(name: 's4') int? s4,@JsonKey(name: 'h1') List<int>? h1,@JsonKey(name: 'h2') List<int>? h2,@JsonKey(name: 'h3') List<int>? h3,@JsonKey(name: 'h4') List<int>? h4
});




}
/// @nodoc
class _$ObfuscationParamsCopyWithImpl<$Res>
    implements $ObfuscationParamsCopyWith<$Res> {
  _$ObfuscationParamsCopyWithImpl(this._self, this._then);

  final ObfuscationParams _self;
  final $Res Function(ObfuscationParams) _then;

/// Create a copy of ObfuscationParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? jc = freezed,Object? jmin = freezed,Object? jmax = freezed,Object? s1 = freezed,Object? s2 = freezed,Object? s3 = freezed,Object? s4 = freezed,Object? h1 = freezed,Object? h2 = freezed,Object? h3 = freezed,Object? h4 = freezed,}) {
  return _then(ObfuscationParams(
jc: freezed == jc ? _self.jc : jc // ignore: cast_nullable_to_non_nullable
as int?,jmin: freezed == jmin ? _self.jmin : jmin // ignore: cast_nullable_to_non_nullable
as int?,jmax: freezed == jmax ? _self.jmax : jmax // ignore: cast_nullable_to_non_nullable
as int?,s1: freezed == s1 ? _self.s1 : s1 // ignore: cast_nullable_to_non_nullable
as int?,s2: freezed == s2 ? _self.s2 : s2 // ignore: cast_nullable_to_non_nullable
as int?,s3: freezed == s3 ? _self.s3 : s3 // ignore: cast_nullable_to_non_nullable
as int?,s4: freezed == s4 ? _self.s4 : s4 // ignore: cast_nullable_to_non_nullable
as int?,h1: freezed == h1 ? _self.h1 : h1 // ignore: cast_nullable_to_non_nullable
as List<int>?,h2: freezed == h2 ? _self.h2 : h2 // ignore: cast_nullable_to_non_nullable
as List<int>?,h3: freezed == h3 ? _self.h3 : h3 // ignore: cast_nullable_to_non_nullable
as List<int>?,h4: freezed == h4 ? _self.h4 : h4 // ignore: cast_nullable_to_non_nullable
as List<int>?,
  ));
}

}


/// Adds pattern-matching-related methods to [ObfuscationParams].
extension ObfuscationParamsPatterns on ObfuscationParams {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ObfuscationParams value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ObfuscationParams() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ObfuscationParams value)  $default,){
final _that = this;
switch (_that) {
case _ObfuscationParams():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ObfuscationParams value)?  $default,){
final _that = this;
switch (_that) {
case _ObfuscationParams() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'jc')  int? jc, @JsonKey(name: 'jmin')  int? jmin, @JsonKey(name: 'jmax')  int? jmax, @JsonKey(name: 's1')  int? s1, @JsonKey(name: 's2')  int? s2, @JsonKey(name: 's3')  int? s3, @JsonKey(name: 's4')  int? s4, @JsonKey(name: 'h1')  List<int>? h1, @JsonKey(name: 'h2')  List<int>? h2, @JsonKey(name: 'h3')  List<int>? h3, @JsonKey(name: 'h4')  List<int>? h4)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ObfuscationParams() when $default != null:
return $default(_that.jc,_that.jmin,_that.jmax,_that.s1,_that.s2,_that.s3,_that.s4,_that.h1,_that.h2,_that.h3,_that.h4);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'jc')  int? jc, @JsonKey(name: 'jmin')  int? jmin, @JsonKey(name: 'jmax')  int? jmax, @JsonKey(name: 's1')  int? s1, @JsonKey(name: 's2')  int? s2, @JsonKey(name: 's3')  int? s3, @JsonKey(name: 's4')  int? s4, @JsonKey(name: 'h1')  List<int>? h1, @JsonKey(name: 'h2')  List<int>? h2, @JsonKey(name: 'h3')  List<int>? h3, @JsonKey(name: 'h4')  List<int>? h4)  $default,) {final _that = this;
switch (_that) {
case _ObfuscationParams():
return $default(_that.jc,_that.jmin,_that.jmax,_that.s1,_that.s2,_that.s3,_that.s4,_that.h1,_that.h2,_that.h3,_that.h4);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'jc')  int? jc, @JsonKey(name: 'jmin')  int? jmin, @JsonKey(name: 'jmax')  int? jmax, @JsonKey(name: 's1')  int? s1, @JsonKey(name: 's2')  int? s2, @JsonKey(name: 's3')  int? s3, @JsonKey(name: 's4')  int? s4, @JsonKey(name: 'h1')  List<int>? h1, @JsonKey(name: 'h2')  List<int>? h2, @JsonKey(name: 'h3')  List<int>? h3, @JsonKey(name: 'h4')  List<int>? h4)?  $default,) {final _that = this;
switch (_that) {
case _ObfuscationParams() when $default != null:
return $default(_that.jc,_that.jmin,_that.jmax,_that.s1,_that.s2,_that.s3,_that.s4,_that.h1,_that.h2,_that.h3,_that.h4);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ObfuscationParams extends ObfuscationParams {
  const _ObfuscationParams({@JsonKey(name: 'jc') this.jc, @JsonKey(name: 'jmin') this.jmin, @JsonKey(name: 'jmax') this.jmax, @JsonKey(name: 's1') this.s1, @JsonKey(name: 's2') this.s2, @JsonKey(name: 's3') this.s3, @JsonKey(name: 's4') this.s4, @JsonKey(name: 'h1')  List<int>? h1, @JsonKey(name: 'h2')  List<int>? h2, @JsonKey(name: 'h3')  List<int>? h3, @JsonKey(name: 'h4')  List<int>? h4}): _h1 = h1,_h2 = h2,_h3 = h3,_h4 = h4,super._();
  factory _ObfuscationParams.fromJson(Map<String, dynamic> json) => _$ObfuscationParamsFromJson(json);

@override@JsonKey(name: 'jc') final  int? jc;
@override@JsonKey(name: 'jmin') final  int? jmin;
@override@JsonKey(name: 'jmax') final  int? jmax;
@override@JsonKey(name: 's1') final  int? s1;
@override@JsonKey(name: 's2') final  int? s2;
@override@JsonKey(name: 's3') final  int? s3;
@override@JsonKey(name: 's4') final  int? s4;
 final  List<int>? _h1;
@override@JsonKey(name: 'h1') List<int>? get h1 {
  final value = _h1;
  if (value == null) return null;
  if (_h1 is EqualUnmodifiableListView) return _h1;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

 final  List<int>? _h2;
@override@JsonKey(name: 'h2') List<int>? get h2 {
  final value = _h2;
  if (value == null) return null;
  if (_h2 is EqualUnmodifiableListView) return _h2;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

 final  List<int>? _h3;
@override@JsonKey(name: 'h3') List<int>? get h3 {
  final value = _h3;
  if (value == null) return null;
  if (_h3 is EqualUnmodifiableListView) return _h3;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

 final  List<int>? _h4;
@override@JsonKey(name: 'h4') List<int>? get h4 {
  final value = _h4;
  if (value == null) return null;
  if (_h4 is EqualUnmodifiableListView) return _h4;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}


/// Create a copy of ObfuscationParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObfuscationParamsCopyWith<_ObfuscationParams> get copyWith => __$ObfuscationParamsCopyWithImpl<_ObfuscationParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ObfuscationParamsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ObfuscationParams&&(identical(other.jc, jc) || other.jc == jc)&&(identical(other.jmin, jmin) || other.jmin == jmin)&&(identical(other.jmax, jmax) || other.jmax == jmax)&&(identical(other.s1, s1) || other.s1 == s1)&&(identical(other.s2, s2) || other.s2 == s2)&&(identical(other.s3, s3) || other.s3 == s3)&&(identical(other.s4, s4) || other.s4 == s4)&&const DeepCollectionEquality().equals(other.h1, _h1)&&const DeepCollectionEquality().equals(other.h2, _h2)&&const DeepCollectionEquality().equals(other.h3, _h3)&&const DeepCollectionEquality().equals(other.h4, _h4));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,jc,jmin,jmax,s1,s2,s3,s4,const DeepCollectionEquality().hash(_h1),const DeepCollectionEquality().hash(_h2),const DeepCollectionEquality().hash(_h3),const DeepCollectionEquality().hash(_h4));
}

@override
String toString() {
    return 'ObfuscationParams(jc: $jc, jmin: $jmin, jmax: $jmax, s1: $s1, s2: $s2, s3: $s3, s4: $s4, h1: $h1, h2: $h2, h3: $h3, h4: $h4)';
}


}

/// @nodoc
abstract mixin class _$ObfuscationParamsCopyWith<$Res> implements $ObfuscationParamsCopyWith<$Res> {
  factory _$ObfuscationParamsCopyWith(_ObfuscationParams value, $Res Function(_ObfuscationParams) _then) = __$ObfuscationParamsCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'jc') int? jc,@JsonKey(name: 'jmin') int? jmin,@JsonKey(name: 'jmax') int? jmax,@JsonKey(name: 's1') int? s1,@JsonKey(name: 's2') int? s2,@JsonKey(name: 's3') int? s3,@JsonKey(name: 's4') int? s4,@JsonKey(name: 'h1') List<int>? h1,@JsonKey(name: 'h2') List<int>? h2,@JsonKey(name: 'h3') List<int>? h3,@JsonKey(name: 'h4') List<int>? h4
});




}
/// @nodoc
class __$ObfuscationParamsCopyWithImpl<$Res>
    implements _$ObfuscationParamsCopyWith<$Res> {
  __$ObfuscationParamsCopyWithImpl(this._self, this._then);

  final _ObfuscationParams _self;
  final $Res Function(_ObfuscationParams) _then;

/// Create a copy of ObfuscationParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? jc = freezed,Object? jmin = freezed,Object? jmax = freezed,Object? s1 = freezed,Object? s2 = freezed,Object? s3 = freezed,Object? s4 = freezed,Object? h1 = freezed,Object? h2 = freezed,Object? h3 = freezed,Object? h4 = freezed,}) {
  return _then(_ObfuscationParams(
jc: freezed == jc ? _self.jc : jc // ignore: cast_nullable_to_non_nullable
as int?,jmin: freezed == jmin ? _self.jmin : jmin // ignore: cast_nullable_to_non_nullable
as int?,jmax: freezed == jmax ? _self.jmax : jmax // ignore: cast_nullable_to_non_nullable
as int?,s1: freezed == s1 ? _self.s1 : s1 // ignore: cast_nullable_to_non_nullable
as int?,s2: freezed == s2 ? _self.s2 : s2 // ignore: cast_nullable_to_non_nullable
as int?,s3: freezed == s3 ? _self.s3 : s3 // ignore: cast_nullable_to_non_nullable
as int?,s4: freezed == s4 ? _self.s4 : s4 // ignore: cast_nullable_to_non_nullable
as int?,h1: freezed == h1 ? _self._h1 : h1 // ignore: cast_nullable_to_non_nullable
as List<int>?,h2: freezed == h2 ? _self._h2 : h2 // ignore: cast_nullable_to_non_nullable
as List<int>?,h3: freezed == h3 ? _self._h3 : h3 // ignore: cast_nullable_to_non_nullable
as List<int>?,h4: freezed == h4 ? _self._h4 : h4 // ignore: cast_nullable_to_non_nullable
as List<int>?,
  ));
}


}


/// @nodoc
mixin _$StreamTransport {

@JsonKey(name: 'server') String get server;@JsonKey(name: 'server_name') String get serverName;@JsonKey(name: 'spki_sha256') List<String> get spkiPins;@JsonKey(name: 'psk') String get psk;@JsonKey(name: 'client_id') String get clientId;
/// Create a copy of StreamTransport
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StreamTransportCopyWith<StreamTransport> get copyWith => _$StreamTransportCopyWithImpl<StreamTransport>(this as StreamTransport, _$identity);

  /// Serializes this StreamTransport to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as StreamTransport;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StreamTransport&&(identical(other.server, _this.server) || other.server == _this.server)&&(identical(other.serverName, _this.serverName) || other.serverName == _this.serverName)&&const DeepCollectionEquality().equals(other.spkiPins, _this.spkiPins)&&(identical(other.psk, _this.psk) || other.psk == _this.psk)&&(identical(other.clientId, _this.clientId) || other.clientId == _this.clientId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as StreamTransport;
  return Object.hash(runtimeType,_this.server,_this.serverName,const DeepCollectionEquality().hash(_this.spkiPins),_this.psk,_this.clientId);
}

@override
String toString() {
  final _this = this as StreamTransport;
  return 'StreamTransport(server: ${_this.server}, serverName: ${_this.serverName}, spkiPins: ${_this.spkiPins}, psk: ${_this.psk}, clientId: ${_this.clientId})';
}


}

/// @nodoc
abstract mixin class $StreamTransportCopyWith<$Res>  {
  factory $StreamTransportCopyWith(StreamTransport value, $Res Function(StreamTransport) _then) = _$StreamTransportCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'server') String server,@JsonKey(name: 'server_name') String serverName,@JsonKey(name: 'spki_sha256') List<String> spkiPins,@JsonKey(name: 'psk') String psk,@JsonKey(name: 'client_id') String clientId
});




}
/// @nodoc
class _$StreamTransportCopyWithImpl<$Res>
    implements $StreamTransportCopyWith<$Res> {
  _$StreamTransportCopyWithImpl(this._self, this._then);

  final StreamTransport _self;
  final $Res Function(StreamTransport) _then;

/// Create a copy of StreamTransport
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? server = null,Object? serverName = null,Object? spkiPins = null,Object? psk = null,Object? clientId = null,}) {
  return _then(StreamTransport(
server: null == server ? _self.server : server // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,spkiPins: null == spkiPins ? _self.spkiPins : spkiPins // ignore: cast_nullable_to_non_nullable
as List<String>,psk: null == psk ? _self.psk : psk // ignore: cast_nullable_to_non_nullable
as String,clientId: null == clientId ? _self.clientId : clientId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [StreamTransport].
extension StreamTransportPatterns on StreamTransport {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _StreamTransport value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _StreamTransport() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _StreamTransport value)  $default,){
final _that = this;
switch (_that) {
case _StreamTransport():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _StreamTransport value)?  $default,){
final _that = this;
switch (_that) {
case _StreamTransport() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'server')  String server, @JsonKey(name: 'server_name')  String serverName, @JsonKey(name: 'spki_sha256')  List<String> spkiPins, @JsonKey(name: 'psk')  String psk, @JsonKey(name: 'client_id')  String clientId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _StreamTransport() when $default != null:
return $default(_that.server,_that.serverName,_that.spkiPins,_that.psk,_that.clientId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'server')  String server, @JsonKey(name: 'server_name')  String serverName, @JsonKey(name: 'spki_sha256')  List<String> spkiPins, @JsonKey(name: 'psk')  String psk, @JsonKey(name: 'client_id')  String clientId)  $default,) {final _that = this;
switch (_that) {
case _StreamTransport():
return $default(_that.server,_that.serverName,_that.spkiPins,_that.psk,_that.clientId);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'server')  String server, @JsonKey(name: 'server_name')  String serverName, @JsonKey(name: 'spki_sha256')  List<String> spkiPins, @JsonKey(name: 'psk')  String psk, @JsonKey(name: 'client_id')  String clientId)?  $default,) {final _that = this;
switch (_that) {
case _StreamTransport() when $default != null:
return $default(_that.server,_that.serverName,_that.spkiPins,_that.psk,_that.clientId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _StreamTransport extends StreamTransport {
  const _StreamTransport({@JsonKey(name: 'server') this.server = '', @JsonKey(name: 'server_name') this.serverName = '', @JsonKey(name: 'spki_sha256')  List<String> spkiPins = const <String>[], @JsonKey(name: 'psk') this.psk = '', @JsonKey(name: 'client_id') this.clientId = ''}): _spkiPins = spkiPins,super._();
  factory _StreamTransport.fromJson(Map<String, dynamic> json) => _$StreamTransportFromJson(json);

@override@JsonKey(name: 'server') final  String server;
@override@JsonKey(name: 'server_name') final  String serverName;
 final  List<String> _spkiPins;
@override@JsonKey(name: 'spki_sha256') List<String> get spkiPins {
  if (_spkiPins is EqualUnmodifiableListView) return _spkiPins;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_spkiPins);
}

@override@JsonKey(name: 'psk') final  String psk;
@override@JsonKey(name: 'client_id') final  String clientId;

/// Create a copy of StreamTransport
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StreamTransportCopyWith<_StreamTransport> get copyWith => __$StreamTransportCopyWithImpl<_StreamTransport>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StreamTransportToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _StreamTransport&&(identical(other.server, server) || other.server == server)&&(identical(other.serverName, serverName) || other.serverName == serverName)&&const DeepCollectionEquality().equals(other.spkiPins, _spkiPins)&&(identical(other.psk, psk) || other.psk == psk)&&(identical(other.clientId, clientId) || other.clientId == clientId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,server,serverName,const DeepCollectionEquality().hash(_spkiPins),psk,clientId);
}

@override
String toString() {
    return 'StreamTransport(server: $server, serverName: $serverName, spkiPins: $spkiPins, psk: $psk, clientId: $clientId)';
}


}

/// @nodoc
abstract mixin class _$StreamTransportCopyWith<$Res> implements $StreamTransportCopyWith<$Res> {
  factory _$StreamTransportCopyWith(_StreamTransport value, $Res Function(_StreamTransport) _then) = __$StreamTransportCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'server') String server,@JsonKey(name: 'server_name') String serverName,@JsonKey(name: 'spki_sha256') List<String> spkiPins,@JsonKey(name: 'psk') String psk,@JsonKey(name: 'client_id') String clientId
});




}
/// @nodoc
class __$StreamTransportCopyWithImpl<$Res>
    implements _$StreamTransportCopyWith<$Res> {
  __$StreamTransportCopyWithImpl(this._self, this._then);

  final _StreamTransport _self;
  final $Res Function(_StreamTransport) _then;

/// Create a copy of StreamTransport
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? server = null,Object? serverName = null,Object? spkiPins = null,Object? psk = null,Object? clientId = null,}) {
  return _then(_StreamTransport(
server: null == server ? _self.server : server // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,spkiPins: null == spkiPins ? _self._spkiPins : spkiPins // ignore: cast_nullable_to_non_nullable
as List<String>,psk: null == psk ? _self.psk : psk // ignore: cast_nullable_to_non_nullable
as String,clientId: null == clientId ? _self.clientId : clientId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$DialParams {

@JsonKey(name: 'id') String get deviceId;@JsonKey(name: 'assigned_ip') String get assignedIp;@JsonKey(name: 'server_id') String get serverId;@JsonKey(name: 'server_name') String get serverName; String get endpoint;@JsonKey(name: 'wg_port') int get wgPort;@JsonKey(name: 'awg_port') int? get awgPort;@JsonKey(name: 'wg_dns') String get wgDns;@JsonKey(name: 'wg_public_key') String get wgPublicKey;@JsonKey(name: 'client_public_key') String? get clientPublicKey;@JsonKey(name: 'obfuscation') Obfuscation? get obfuscation;@JsonKey(name: 'stream') StreamTransport? get stream;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DialParams&&(identical(other.deviceId, _this.deviceId) || other.deviceId == _this.deviceId)&&(identical(other.assignedIp, _this.assignedIp) || other.assignedIp == _this.assignedIp)&&(identical(other.serverId, _this.serverId) || other.serverId == _this.serverId)&&(identical(other.serverName, _this.serverName) || other.serverName == _this.serverName)&&(identical(other.endpoint, _this.endpoint) || other.endpoint == _this.endpoint)&&(identical(other.wgPort, _this.wgPort) || other.wgPort == _this.wgPort)&&(identical(other.awgPort, _this.awgPort) || other.awgPort == _this.awgPort)&&(identical(other.wgDns, _this.wgDns) || other.wgDns == _this.wgDns)&&(identical(other.wgPublicKey, _this.wgPublicKey) || other.wgPublicKey == _this.wgPublicKey)&&(identical(other.clientPublicKey, _this.clientPublicKey) || other.clientPublicKey == _this.clientPublicKey)&&(identical(other.obfuscation, _this.obfuscation) || other.obfuscation == _this.obfuscation)&&(identical(other.stream, _this.stream) || other.stream == _this.stream));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as DialParams;
  return Object.hash(runtimeType,_this.deviceId,_this.assignedIp,_this.serverId,_this.serverName,_this.endpoint,_this.wgPort,_this.awgPort,_this.wgDns,_this.wgPublicKey,_this.clientPublicKey,_this.obfuscation,_this.stream);
}

@override
String toString() {
  final _this = this as DialParams;
  return 'DialParams(deviceId: ${_this.deviceId}, assignedIp: ${_this.assignedIp}, serverId: ${_this.serverId}, serverName: ${_this.serverName}, endpoint: ${_this.endpoint}, wgPort: ${_this.wgPort}, awgPort: ${_this.awgPort}, wgDns: ${_this.wgDns}, wgPublicKey: ${_this.wgPublicKey}, clientPublicKey: ${_this.clientPublicKey}, obfuscation: ${_this.obfuscation}, stream: ${_this.stream})';
}


}

/// @nodoc
abstract mixin class $DialParamsCopyWith<$Res>  {
  factory $DialParamsCopyWith(DialParams value, $Res Function(DialParams) _then) = _$DialParamsCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'id') String deviceId,@JsonKey(name: 'assigned_ip') String assignedIp,@JsonKey(name: 'server_id') String serverId,@JsonKey(name: 'server_name') String serverName, String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'awg_port') int? awgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String wgPublicKey,@JsonKey(name: 'client_public_key') String? clientPublicKey,@JsonKey(name: 'obfuscation') Obfuscation? obfuscation,@JsonKey(name: 'stream') StreamTransport? stream
});


$ObfuscationCopyWith<$Res>? get obfuscation;$StreamTransportCopyWith<$Res>? get stream;

}
/// @nodoc
class _$DialParamsCopyWithImpl<$Res>
    implements $DialParamsCopyWith<$Res> {
  _$DialParamsCopyWithImpl(this._self, this._then);

  final DialParams _self;
  final $Res Function(DialParams) _then;

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? deviceId = null,Object? assignedIp = null,Object? serverId = null,Object? serverName = null,Object? endpoint = null,Object? wgPort = null,Object? awgPort = freezed,Object? wgDns = null,Object? wgPublicKey = null,Object? clientPublicKey = freezed,Object? obfuscation = freezed,Object? stream = freezed,}) {
  return _then(DialParams(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,assignedIp: null == assignedIp ? _self.assignedIp : assignedIp // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,awgPort: freezed == awgPort ? _self.awgPort : awgPort // ignore: cast_nullable_to_non_nullable
as int?,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: null == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String,clientPublicKey: freezed == clientPublicKey ? _self.clientPublicKey : clientPublicKey // ignore: cast_nullable_to_non_nullable
as String?,obfuscation: freezed == obfuscation ? _self.obfuscation : obfuscation // ignore: cast_nullable_to_non_nullable
as Obfuscation?,stream: freezed == stream ? _self.stream : stream // ignore: cast_nullable_to_non_nullable
as StreamTransport?,
  ));
}
/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationCopyWith<$Res>? get obfuscation {
    if (_self.obfuscation == null) {
    return null;
  }

  return $ObfuscationCopyWith<$Res>(_self.obfuscation!, (value) {
    return _then(_self.copyWith(obfuscation: value));
  });
}/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$StreamTransportCopyWith<$Res>? get stream {
    if (_self.stream == null) {
    return null;
  }

  return $StreamTransportCopyWith<$Res>(_self.stream!, (value) {
    return _then(_self.copyWith(stream: value));
  });
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'awg_port')  int? awgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation, @JsonKey(name: 'stream')  StreamTransport? stream)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.awgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey,_that.obfuscation,_that.stream);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'awg_port')  int? awgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation, @JsonKey(name: 'stream')  StreamTransport? stream)  $default,) {final _that = this;
switch (_that) {
case _DialParams():
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.awgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey,_that.obfuscation,_that.stream);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'id')  String deviceId, @JsonKey(name: 'assigned_ip')  String assignedIp, @JsonKey(name: 'server_id')  String serverId, @JsonKey(name: 'server_name')  String serverName,  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'awg_port')  int? awgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String wgPublicKey, @JsonKey(name: 'client_public_key')  String? clientPublicKey, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation, @JsonKey(name: 'stream')  StreamTransport? stream)?  $default,) {final _that = this;
switch (_that) {
case _DialParams() when $default != null:
return $default(_that.deviceId,_that.assignedIp,_that.serverId,_that.serverName,_that.endpoint,_that.wgPort,_that.awgPort,_that.wgDns,_that.wgPublicKey,_that.clientPublicKey,_that.obfuscation,_that.stream);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DialParams implements DialParams {
  const _DialParams({@JsonKey(name: 'id') required this.deviceId, @JsonKey(name: 'assigned_ip') required this.assignedIp, @JsonKey(name: 'server_id') required this.serverId, @JsonKey(name: 'server_name') this.serverName = '', required this.endpoint, @JsonKey(name: 'wg_port') required this.wgPort, @JsonKey(name: 'awg_port') this.awgPort, @JsonKey(name: 'wg_dns') required this.wgDns, @JsonKey(name: 'wg_public_key') required this.wgPublicKey, @JsonKey(name: 'client_public_key') this.clientPublicKey, @JsonKey(name: 'obfuscation') this.obfuscation, @JsonKey(name: 'stream') this.stream});
  factory _DialParams.fromJson(Map<String, dynamic> json) => _$DialParamsFromJson(json);

@override@JsonKey(name: 'id') final  String deviceId;
@override@JsonKey(name: 'assigned_ip') final  String assignedIp;
@override@JsonKey(name: 'server_id') final  String serverId;
@override@JsonKey(name: 'server_name') final  String serverName;
@override final  String endpoint;
@override@JsonKey(name: 'wg_port') final  int wgPort;
@override@JsonKey(name: 'awg_port') final  int? awgPort;
@override@JsonKey(name: 'wg_dns') final  String wgDns;
@override@JsonKey(name: 'wg_public_key') final  String wgPublicKey;
@override@JsonKey(name: 'client_public_key') final  String? clientPublicKey;
@override@JsonKey(name: 'obfuscation') final  Obfuscation? obfuscation;
@override@JsonKey(name: 'stream') final  StreamTransport? stream;

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
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DialParams&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.assignedIp, assignedIp) || other.assignedIp == assignedIp)&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.serverName, serverName) || other.serverName == serverName)&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.wgPort, wgPort) || other.wgPort == wgPort)&&(identical(other.awgPort, awgPort) || other.awgPort == awgPort)&&(identical(other.wgDns, wgDns) || other.wgDns == wgDns)&&(identical(other.wgPublicKey, wgPublicKey) || other.wgPublicKey == wgPublicKey)&&(identical(other.clientPublicKey, clientPublicKey) || other.clientPublicKey == clientPublicKey)&&(identical(other.obfuscation, obfuscation) || other.obfuscation == obfuscation)&&(identical(other.stream, stream) || other.stream == stream));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,deviceId,assignedIp,serverId,serverName,endpoint,wgPort,awgPort,wgDns,wgPublicKey,clientPublicKey,obfuscation,stream);
}

@override
String toString() {
    return 'DialParams(deviceId: $deviceId, assignedIp: $assignedIp, serverId: $serverId, serverName: $serverName, endpoint: $endpoint, wgPort: $wgPort, awgPort: $awgPort, wgDns: $wgDns, wgPublicKey: $wgPublicKey, clientPublicKey: $clientPublicKey, obfuscation: $obfuscation, stream: $stream)';
}


}

/// @nodoc
abstract mixin class _$DialParamsCopyWith<$Res> implements $DialParamsCopyWith<$Res> {
  factory _$DialParamsCopyWith(_DialParams value, $Res Function(_DialParams) _then) = __$DialParamsCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'id') String deviceId,@JsonKey(name: 'assigned_ip') String assignedIp,@JsonKey(name: 'server_id') String serverId,@JsonKey(name: 'server_name') String serverName, String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'awg_port') int? awgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String wgPublicKey,@JsonKey(name: 'client_public_key') String? clientPublicKey,@JsonKey(name: 'obfuscation') Obfuscation? obfuscation,@JsonKey(name: 'stream') StreamTransport? stream
});


@override $ObfuscationCopyWith<$Res>? get obfuscation;@override $StreamTransportCopyWith<$Res>? get stream;

}
/// @nodoc
class __$DialParamsCopyWithImpl<$Res>
    implements _$DialParamsCopyWith<$Res> {
  __$DialParamsCopyWithImpl(this._self, this._then);

  final _DialParams _self;
  final $Res Function(_DialParams) _then;

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? assignedIp = null,Object? serverId = null,Object? serverName = null,Object? endpoint = null,Object? wgPort = null,Object? awgPort = freezed,Object? wgDns = null,Object? wgPublicKey = null,Object? clientPublicKey = freezed,Object? obfuscation = freezed,Object? stream = freezed,}) {
  return _then(_DialParams(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,assignedIp: null == assignedIp ? _self.assignedIp : assignedIp // ignore: cast_nullable_to_non_nullable
as String,serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,serverName: null == serverName ? _self.serverName : serverName // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,awgPort: freezed == awgPort ? _self.awgPort : awgPort // ignore: cast_nullable_to_non_nullable
as int?,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: null == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String,clientPublicKey: freezed == clientPublicKey ? _self.clientPublicKey : clientPublicKey // ignore: cast_nullable_to_non_nullable
as String?,obfuscation: freezed == obfuscation ? _self.obfuscation : obfuscation // ignore: cast_nullable_to_non_nullable
as Obfuscation?,stream: freezed == stream ? _self.stream : stream // ignore: cast_nullable_to_non_nullable
as StreamTransport?,
  ));
}

/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationCopyWith<$Res>? get obfuscation {
    if (_self.obfuscation == null) {
    return null;
  }

  return $ObfuscationCopyWith<$Res>(_self.obfuscation!, (value) {
    return _then(_self.copyWith(obfuscation: value));
  });
}/// Create a copy of DialParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$StreamTransportCopyWith<$Res>? get stream {
    if (_self.stream == null) {
    return null;
  }

  return $StreamTransportCopyWith<$Res>(_self.stream!, (value) {
    return _then(_self.copyWith(stream: value));
  });
}
}


/// @nodoc
mixin _$DiscoveryServer {

 String get id; String get name;@JsonKey(readValue: _readDialHost) String get endpoint;@JsonKey(name: 'wg_port') int get wgPort;@JsonKey(name: 'wg_dns') String get wgDns;@JsonKey(name: 'wg_public_key') String? get wgPublicKey;@JsonKey(name: 'active_peers') int get activePeers;@JsonKey(name: 'obfuscation') Obfuscation? get obfuscation;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DiscoveryServer&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.endpoint, _this.endpoint) || other.endpoint == _this.endpoint)&&(identical(other.wgPort, _this.wgPort) || other.wgPort == _this.wgPort)&&(identical(other.wgDns, _this.wgDns) || other.wgDns == _this.wgDns)&&(identical(other.wgPublicKey, _this.wgPublicKey) || other.wgPublicKey == _this.wgPublicKey)&&(identical(other.activePeers, _this.activePeers) || other.activePeers == _this.activePeers)&&(identical(other.obfuscation, _this.obfuscation) || other.obfuscation == _this.obfuscation));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as DiscoveryServer;
  return Object.hash(runtimeType,_this.id,_this.name,_this.endpoint,_this.wgPort,_this.wgDns,_this.wgPublicKey,_this.activePeers,_this.obfuscation);
}

@override
String toString() {
  final _this = this as DiscoveryServer;
  return 'DiscoveryServer(id: ${_this.id}, name: ${_this.name}, endpoint: ${_this.endpoint}, wgPort: ${_this.wgPort}, wgDns: ${_this.wgDns}, wgPublicKey: ${_this.wgPublicKey}, activePeers: ${_this.activePeers}, obfuscation: ${_this.obfuscation})';
}


}

/// @nodoc
abstract mixin class $DiscoveryServerCopyWith<$Res>  {
  factory $DiscoveryServerCopyWith(DiscoveryServer value, $Res Function(DiscoveryServer) _then) = _$DiscoveryServerCopyWithImpl;
@useResult
$Res call({
 String id, String name,@JsonKey(readValue: _readDialHost) String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String? wgPublicKey,@JsonKey(name: 'active_peers') int activePeers,@JsonKey(name: 'obfuscation') Obfuscation? obfuscation
});


$ObfuscationCopyWith<$Res>? get obfuscation;

}
/// @nodoc
class _$DiscoveryServerCopyWithImpl<$Res>
    implements $DiscoveryServerCopyWith<$Res> {
  _$DiscoveryServerCopyWithImpl(this._self, this._then);

  final DiscoveryServer _self;
  final $Res Function(DiscoveryServer) _then;

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = freezed,Object? activePeers = null,Object? obfuscation = freezed,}) {
  return _then(DiscoveryServer(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: freezed == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
as int,obfuscation: freezed == obfuscation ? _self.obfuscation : obfuscation // ignore: cast_nullable_to_non_nullable
as Obfuscation?,
  ));
}
/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationCopyWith<$Res>? get obfuscation {
    if (_self.obfuscation == null) {
    return null;
  }

  return $ObfuscationCopyWith<$Res>(_self.obfuscation!, (value) {
    return _then(_self.copyWith(obfuscation: value));
  });
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers,_that.obfuscation);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation)  $default,) {final _that = this;
switch (_that) {
case _DiscoveryServer():
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers,_that.obfuscation);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name, @JsonKey(readValue: _readDialHost)  String endpoint, @JsonKey(name: 'wg_port')  int wgPort, @JsonKey(name: 'wg_dns')  String wgDns, @JsonKey(name: 'wg_public_key')  String? wgPublicKey, @JsonKey(name: 'active_peers')  int activePeers, @JsonKey(name: 'obfuscation')  Obfuscation? obfuscation)?  $default,) {final _that = this;
switch (_that) {
case _DiscoveryServer() when $default != null:
return $default(_that.id,_that.name,_that.endpoint,_that.wgPort,_that.wgDns,_that.wgPublicKey,_that.activePeers,_that.obfuscation);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DiscoveryServer extends DiscoveryServer {
  const _DiscoveryServer({required this.id, this.name = '', @JsonKey(readValue: _readDialHost) this.endpoint = '', @JsonKey(name: 'wg_port') required this.wgPort, @JsonKey(name: 'wg_dns') this.wgDns = '', @JsonKey(name: 'wg_public_key') this.wgPublicKey, @JsonKey(name: 'active_peers') this.activePeers = 0, @JsonKey(name: 'obfuscation') this.obfuscation}): super._();
  factory _DiscoveryServer.fromJson(Map<String, dynamic> json) => _$DiscoveryServerFromJson(json);

@override final  String id;
@override@JsonKey() final  String name;
@override@JsonKey(readValue: _readDialHost) final  String endpoint;
@override@JsonKey(name: 'wg_port') final  int wgPort;
@override@JsonKey(name: 'wg_dns') final  String wgDns;
@override@JsonKey(name: 'wg_public_key') final  String? wgPublicKey;
@override@JsonKey(name: 'active_peers') final  int activePeers;
@override@JsonKey(name: 'obfuscation') final  Obfuscation? obfuscation;

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
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _DiscoveryServer&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.wgPort, wgPort) || other.wgPort == wgPort)&&(identical(other.wgDns, wgDns) || other.wgDns == wgDns)&&(identical(other.wgPublicKey, wgPublicKey) || other.wgPublicKey == wgPublicKey)&&(identical(other.activePeers, activePeers) || other.activePeers == activePeers)&&(identical(other.obfuscation, obfuscation) || other.obfuscation == obfuscation));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,endpoint,wgPort,wgDns,wgPublicKey,activePeers,obfuscation);
}

@override
String toString() {
    return 'DiscoveryServer(id: $id, name: $name, endpoint: $endpoint, wgPort: $wgPort, wgDns: $wgDns, wgPublicKey: $wgPublicKey, activePeers: $activePeers, obfuscation: $obfuscation)';
}


}

/// @nodoc
abstract mixin class _$DiscoveryServerCopyWith<$Res> implements $DiscoveryServerCopyWith<$Res> {
  factory _$DiscoveryServerCopyWith(_DiscoveryServer value, $Res Function(_DiscoveryServer) _then) = __$DiscoveryServerCopyWithImpl;
@override @useResult
$Res call({
 String id, String name,@JsonKey(readValue: _readDialHost) String endpoint,@JsonKey(name: 'wg_port') int wgPort,@JsonKey(name: 'wg_dns') String wgDns,@JsonKey(name: 'wg_public_key') String? wgPublicKey,@JsonKey(name: 'active_peers') int activePeers,@JsonKey(name: 'obfuscation') Obfuscation? obfuscation
});


@override $ObfuscationCopyWith<$Res>? get obfuscation;

}
/// @nodoc
class __$DiscoveryServerCopyWithImpl<$Res>
    implements _$DiscoveryServerCopyWith<$Res> {
  __$DiscoveryServerCopyWithImpl(this._self, this._then);

  final _DiscoveryServer _self;
  final $Res Function(_DiscoveryServer) _then;

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? endpoint = null,Object? wgPort = null,Object? wgDns = null,Object? wgPublicKey = freezed,Object? activePeers = null,Object? obfuscation = freezed,}) {
  return _then(_DiscoveryServer(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,wgPort: null == wgPort ? _self.wgPort : wgPort // ignore: cast_nullable_to_non_nullable
as int,wgDns: null == wgDns ? _self.wgDns : wgDns // ignore: cast_nullable_to_non_nullable
as String,wgPublicKey: freezed == wgPublicKey ? _self.wgPublicKey : wgPublicKey // ignore: cast_nullable_to_non_nullable
as String?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
as int,obfuscation: freezed == obfuscation ? _self.obfuscation : obfuscation // ignore: cast_nullable_to_non_nullable
as Obfuscation?,
  ));
}

/// Create a copy of DiscoveryServer
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObfuscationCopyWith<$Res>? get obfuscation {
    if (_self.obfuscation == null) {
    return null;
  }

  return $ObfuscationCopyWith<$Res>(_self.obfuscation!, (value) {
    return _then(_self.copyWith(obfuscation: value));
  });
}
}


/// @nodoc
mixin _$ServerStatus {

@JsonKey(name: 'server_id') String get serverId; String get name;@JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire) ServerHealth? get status;@JsonKey(name: 'active_peers') int get activePeers;
/// Create a copy of ServerStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerStatusCopyWith<ServerStatus> get copyWith => _$ServerStatusCopyWithImpl<ServerStatus>(this as ServerStatus, _$identity);

  /// Serializes this ServerStatus to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ServerStatus;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerStatus&&(identical(other.serverId, _this.serverId) || other.serverId == _this.serverId)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.activePeers, _this.activePeers) || other.activePeers == _this.activePeers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ServerStatus;
  return Object.hash(runtimeType,_this.serverId,_this.name,_this.status,_this.activePeers);
}

@override
String toString() {
  final _this = this as ServerStatus;
  return 'ServerStatus(serverId: ${_this.serverId}, name: ${_this.name}, status: ${_this.status}, activePeers: ${_this.activePeers})';
}


}

/// @nodoc
abstract mixin class $ServerStatusCopyWith<$Res>  {
  factory $ServerStatusCopyWith(ServerStatus value, $Res Function(ServerStatus) _then) = _$ServerStatusCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'server_id') String serverId, String name,@JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire) ServerHealth? status,@JsonKey(name: 'active_peers') int activePeers
});




}
/// @nodoc
class _$ServerStatusCopyWithImpl<$Res>
    implements $ServerStatusCopyWith<$Res> {
  _$ServerStatusCopyWithImpl(this._self, this._then);

  final ServerStatus _self;
  final $Res Function(ServerStatus) _then;

/// Create a copy of ServerStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? serverId = null,Object? name = null,Object? status = freezed,Object? activePeers = null,}) {
  return _then(ServerStatus(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ServerHealth?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerStatus].
extension ServerStatusPatterns on ServerStatus {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerStatus value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerStatus() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerStatus value)  $default,){
final _that = this;
switch (_that) {
case _ServerStatus():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerStatus value)?  $default,){
final _that = this;
switch (_that) {
case _ServerStatus() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'server_id')  String serverId,  String name, @JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire)  ServerHealth? status, @JsonKey(name: 'active_peers')  int activePeers)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerStatus() when $default != null:
return $default(_that.serverId,_that.name,_that.status,_that.activePeers);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'server_id')  String serverId,  String name, @JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire)  ServerHealth? status, @JsonKey(name: 'active_peers')  int activePeers)  $default,) {final _that = this;
switch (_that) {
case _ServerStatus():
return $default(_that.serverId,_that.name,_that.status,_that.activePeers);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'server_id')  String serverId,  String name, @JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire)  ServerHealth? status, @JsonKey(name: 'active_peers')  int activePeers)?  $default,) {final _that = this;
switch (_that) {
case _ServerStatus() when $default != null:
return $default(_that.serverId,_that.name,_that.status,_that.activePeers);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ServerStatus extends ServerStatus {
  const _ServerStatus({@JsonKey(name: 'server_id') required this.serverId, this.name = '', @JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire) this.status, @JsonKey(name: 'active_peers') this.activePeers = 0}): super._();
  factory _ServerStatus.fromJson(Map<String, dynamic> json) => _$ServerStatusFromJson(json);

@override@JsonKey(name: 'server_id') final  String serverId;
@override@JsonKey() final  String name;
@override@JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire) final  ServerHealth? status;
@override@JsonKey(name: 'active_peers') final  int activePeers;

/// Create a copy of ServerStatus
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerStatusCopyWith<_ServerStatus> get copyWith => __$ServerStatusCopyWithImpl<_ServerStatus>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ServerStatusToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerStatus&&(identical(other.serverId, serverId) || other.serverId == serverId)&&(identical(other.name, name) || other.name == name)&&(identical(other.status, status) || other.status == status)&&(identical(other.activePeers, activePeers) || other.activePeers == activePeers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,serverId,name,status,activePeers);
}

@override
String toString() {
    return 'ServerStatus(serverId: $serverId, name: $name, status: $status, activePeers: $activePeers)';
}


}

/// @nodoc
abstract mixin class _$ServerStatusCopyWith<$Res> implements $ServerStatusCopyWith<$Res> {
  factory _$ServerStatusCopyWith(_ServerStatus value, $Res Function(_ServerStatus) _then) = __$ServerStatusCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'server_id') String serverId, String name,@JsonKey(name: 'status', fromJson: ServerHealth.fromWire, toJson: _serverHealthToWire) ServerHealth? status,@JsonKey(name: 'active_peers') int activePeers
});




}
/// @nodoc
class __$ServerStatusCopyWithImpl<$Res>
    implements _$ServerStatusCopyWith<$Res> {
  __$ServerStatusCopyWithImpl(this._self, this._then);

  final _ServerStatus _self;
  final $Res Function(_ServerStatus) _then;

/// Create a copy of ServerStatus
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? serverId = null,Object? name = null,Object? status = freezed,Object? activePeers = null,}) {
  return _then(_ServerStatus(
serverId: null == serverId ? _self.serverId : serverId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ServerHealth?,activePeers: null == activePeers ? _self.activePeers : activePeers // ignore: cast_nullable_to_non_nullable
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
