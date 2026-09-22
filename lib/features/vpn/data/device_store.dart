import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage_options.dart';

/// Device identity secrets for the VPN flow.
///
/// Keys never leave the device except `deviceId` (path param) and the
/// public key (request body). The private key is never sent.
class DeviceStore {
  static const deviceIdKey = 'boltmesh_device_id';

  /// The X25519 keypair as one JSON entry (`{priv, pub}`) so both halves land
  /// atomically: two separate writes could crash between them and leave a
  /// private key with no public half (or vice versa).
  static const keypairKey = 'boltmesh_keypair';
  static const deviceNameKey = 'boltmesh_device_name';
  static const provisionKeyKey = 'boltmesh_provision_idempotency_key';
  static const provisionTargetKey = 'boltmesh_provision_target';
  static const lastRegionKey = 'boltmesh_last_region_id';
  static const lastServerKey = 'boltmesh_last_server_id';
  static const lastExplicitKey = 'boltmesh_last_target_explicit';

  /// Last known-good dial params as a JSON string (see `DialParams.toJson`).
  /// Written on every successful tunnel start, read only by cold-start
  /// reconciliation to render an optimistic Connected state while the
  /// server truth (`GET …/config`) is still in flight or unreachable.
  /// Kept as an opaque string (never a model) so this store stays free of
  /// model imports; the controller owns encode/decode. Cleared with the
  /// device and on explicit disconnect (the tunnel is down, so a cached
  /// dial must never resurrect it).
  static const lastDialKey = 'boltmesh_last_dial_json';

  /// Split-tunnel preference: `'1'` = allow LAN (default), `'0'` = strict
  /// full tunnel. A non-secret UI preference, kept here (rather than a new
  /// SharedPreferences dependency) alongside the other tunnel settings.
  static const allowLocalKey = 'boltmesh_allow_local';

  final FlutterSecureStorage _s;
  const DeviceStore([this._s = kSharedSecureStorage]);

  Future<String?> deviceId() => _s.read(key: deviceIdKey);
  Future<void> setDeviceId(String v) => _s.write(key: deviceIdKey, value: v);

  /// Wipes the device identity. The custom device name is identity, not a
  /// UI preference: leaving it behind would make the next account on this
  /// install silently inherit the previous user's name (see `_provision`).
  /// [allowLocalKey] is the one deliberate survivor (see [allowLocal]).
  Future<void> clearDevice() => Future.wait([
    _s.delete(key: deviceIdKey),
    _s.delete(key: keypairKey),
    _s.delete(key: deviceNameKey),
    _s.delete(key: provisionKeyKey),
    _s.delete(key: provisionTargetKey),
    _s.delete(key: lastRegionKey),
    _s.delete(key: lastServerKey),
    _s.delete(key: lastExplicitKey),
    _s.delete(key: lastDialKey),
  ]);

  Future<({String? privateKey, String? publicKey})> _keypair() async {
    final raw = await _s.read(key: keypairKey);
    if (raw == null) return (privateKey: null, publicKey: null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return (
          privateKey: decoded['priv'] as String?,
          publicKey: decoded['pub'] as String?,
        );
      }
    } catch (_) {
      // A corrupt entry reads as "no keypair"; provisioning regenerates it.
    }
    return (privateKey: null, publicKey: null);
  }

  Future<String?> privateKey() async => (await _keypair()).privateKey;
  Future<String?> publicKey() async => (await _keypair()).publicKey;
  Future<void> setKeypair({
    required String privateKey,
    required String publicKey,
  }) => _s.write(
    key: keypairKey,
    value: jsonEncode({'priv': privateKey, 'pub': publicKey}),
  );

  Future<String?> deviceName() => _s.read(key: deviceNameKey);
  Future<void> setDeviceName(String v) =>
      _s.write(key: deviceNameKey, value: v);

  /// One UUID per provisioning attempt; persisted until 201/200 so
  /// retries reuse the same `Idempotency-Key` instead of consuming
  /// extra device slots.
  Future<String?> provisionKey() => _s.read(key: provisionKeyKey);
  Future<void> setProvisionKey(String v) =>
      _s.write(key: provisionKeyKey, value: v);
  Future<void> clearProvisionKey() => Future.wait([
    _s.delete(key: provisionKeyKey),
    _s.delete(key: provisionTargetKey),
  ]);

  /// Target (`regionId|serverId`) the pending idempotency key was minted
  /// for. A retry with a different target must mint a fresh key: reusing the
  /// same `Idempotency-Key` with a different body 409s forever
  /// (`IdempotencyKeyBodyConflictError`).
  Future<String?> provisionTarget() => _s.read(key: provisionTargetKey);
  Future<void> setProvisionTarget(String v) =>
      _s.write(key: provisionTargetKey, value: v);

  /// Last user-selected connection target. Persisted so a disconnect →
  /// connect (and a restart with a GC'd peer) redials the same server or
  /// region instead of auto-picking. Exactly one side is non-null by
  /// contract (see `selectTarget`). [explicitTarget] records whether the
  /// pin came from a manual tap (constrains auto-failover to the region)
  /// or an auto-pick (failover may roam globally). Cleared with the device
  /// on logout or session revocation so it never leaks into the next login.
  Future<({String? regionId, String? serverId, bool explicitTarget})>
  lastTarget() async {
    final results = await Future.wait([
      _s.read(key: lastRegionKey),
      _s.read(key: lastServerKey),
      _s.read(key: lastExplicitKey),
    ]);
    return (
      regionId: results[0],
      serverId: results[1],
      explicitTarget: results[2] == '1',
    );
  }

  Future<void> setLastTarget({
    required String? regionId,
    required String? serverId,
    required bool explicitTarget,
  }) async {
    await Future.wait([
      regionId == null
          ? _s.delete(key: lastRegionKey)
          : _s.write(key: lastRegionKey, value: regionId),
      serverId == null
          ? _s.delete(key: lastServerKey)
          : _s.write(key: lastServerKey, value: serverId),
      _s.write(key: lastExplicitKey, value: explicitTarget ? '1' : '0'),
    ]);
  }

  Future<String?> lastDialJson() => _s.read(key: lastDialKey);
  Future<void> setLastDialJson(String v) =>
      _s.write(key: lastDialKey, value: v);
  Future<void> clearLastDial() => _s.delete(key: lastDialKey);

  /// True unless explicitly set to `'0'`: unset or corrupt values default
  /// to ON so local devices keep working out of the box. Survives
  /// [clearDevice] (a preference, not device identity).
  Future<bool> allowLocal() async {
    final raw = await _s.read(key: allowLocalKey);
    return raw != '0';
  }

  Future<void> setAllowLocal(bool v) =>
      _s.write(key: allowLocalKey, value: v ? '1' : '0');
}

/// Shared device-identity backing for the tunnel controller and settings.
final deviceStoreProvider = Provider((_) => const DeviceStore());
