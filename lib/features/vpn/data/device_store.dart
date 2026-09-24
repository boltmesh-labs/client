import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/mutex.dart';
import '../../../core/storage_options.dart';

/// Longest device name the backend accepts for `VpnDeviceCreateIn.name` and
/// `VpnDeviceUpdateIn.name` (`max_length=64`). Enforced on save so an
/// over-long name can never be stored and then fail every provisioning call
/// with a 422.
const maxDeviceNameLength = 64;

/// Device identity secrets for the VPN flow.
///
/// Everything that belongs to one device identity — id, keypair, custom
/// name, pending provisioning key/target, the last selected target and the
/// cached dial — lives in one JSON document under [identityKey]. A single
/// entry makes [clearDevice] one atomic delete, so a failed wipe can never
/// strand a subset of the identity, and the last-target triple
/// (`regionId` + `serverId` + `explicit`) is written as one value instead of
/// three independent keys that could interleave and persist both sides.
///
/// Every mutation is serialized through [_mutex] in call order. Two writers
/// can no longer race a read-modify-write, and a wipe can never complete
/// before an older, already-queued write — which is what let a logged-out
/// account's target reappear for the next login.
///
/// [allowLocalKey] is deliberately *outside* the document: the split-tunnel
/// preference is not identity and survives [clearDevice] (see [allowLocal]).
///
/// Keys never leave the device except `deviceId` (path param) and the
/// public key (request body). The private key is never sent.
class DeviceStore {
  /// Single JSON document holding the whole device identity. See the class
  /// doc for why this is one entry rather than one key per field.
  static const identityKey = 'boltmesh_device_identity';

  /// Split-tunnel preference: `'1'` = allow LAN (default), `'0'` = strict
  /// full tunnel. A non-secret UI preference, kept in its own entry so it
  /// deliberately survives [clearDevice].
  static const allowLocalKey = 'boltmesh_allow_local';

  final FlutterSecureStorage _s;

  /// Serializes every identity mutation (and the atomic wipe) in call order.
  final AsyncMutex _mutex = AsyncMutex();

  DeviceStore([this._s = kSharedSecureStorage]);

  /// Decodes the identity document, tolerating a missing or corrupt entry as
  /// an empty identity (the next write replaces it).
  Future<Map<String, dynamic>> _doc() async {
    final raw = await _s.read(key: identityKey);
    if (raw == null) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // A corrupt entry reads as "no identity"; provisioning regenerates it.
    }
    return <String, dynamic>{};
  }

  /// Runs [change] against the current document under the store lock, then
  /// writes the whole document back as one value. The lock is acquired
  /// synchronously (the first statement of this async body), so a caller's
  /// operation is enqueued in the same turn it is invoked — FIFO order is the
  /// caller's call order.
  Future<void> _mutate(void Function(Map<String, dynamic> doc) change) async {
    final release = await _mutex.acquire('device-store');
    try {
      final doc = await _doc();
      change(doc);
      await _s.write(key: identityKey, value: jsonEncode(doc));
    } finally {
      release();
    }
  }

  String? _string(Map<String, dynamic> doc, String key) {
    final value = doc[key];
    return value is String ? value : null;
  }

  Future<String?> deviceId() async => _string(await _doc(), 'deviceId');
  Future<void> setDeviceId(String v) => _mutate((d) => d['deviceId'] = v);

  /// Reads the X25519 keypair, or nulls when absent/corrupt.
  ///
  /// Stored as one nested entry so both halves always change together: two
  /// separate writes could crash between them and leave a private key with no
  /// public half (or vice versa).
  Future<({String? privateKey, String? publicKey})> _keypair() async {
    final kp = (await _doc())['keypair'];
    if (kp is Map) {
      return (
        privateKey: kp['priv'] is String ? kp['priv'] as String : null,
        publicKey: kp['pub'] is String ? kp['pub'] as String : null,
      );
    }
    return (privateKey: null, publicKey: null);
  }

  Future<String?> privateKey() async => (await _keypair()).privateKey;
  Future<String?> publicKey() async => (await _keypair()).publicKey;
  Future<void> setKeypair({
    required String privateKey,
    required String publicKey,
  }) => _mutate((d) => d['keypair'] = {'priv': privateKey, 'pub': publicKey});

  Future<String?> deviceName() async => _string(await _doc(), 'deviceName');

  /// Stores the custom device name. Rejects an empty or over-long name here
  /// (mirroring the backend's strip + `1..maxDeviceNameLength` contract) so
  /// the Settings editor and any other caller cannot persist a name the
  /// backend will refuse at provisioning time.
  Future<void> setDeviceName(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty || trimmed.runes.length > maxDeviceNameLength) {
      throw ArgumentError.value(
        v,
        'v',
        'device name must be 1..$maxDeviceNameLength characters',
      );
    }
    return _mutate((d) => d['deviceName'] = v);
  }

  /// One UUID per provisioning attempt; persisted until 201/200 so
  /// retries reuse the same `Idempotency-Key` instead of consuming
  /// extra device slots.
  Future<String?> provisionKey() async => _string(await _doc(), 'provisionKey');
  Future<void> setProvisionKey(String v) =>
      _mutate((d) => d['provisionKey'] = v);

  /// Target (`regionId|serverId`) the pending idempotency key was minted
  /// for. A retry with a different target must mint a fresh key: reusing the
  /// same `Idempotency-Key` with a different body 409s forever
  /// (`IdempotencyKeyBodyConflictError`).
  Future<String?> provisionTarget() async =>
      _string(await _doc(), 'provisionTarget');
  Future<void> setProvisionTarget(String v) =>
      _mutate((d) => d['provisionTarget'] = v);

  Future<void> clearProvisionKey() => _mutate(
    (d) => d
      ..remove('provisionKey')
      ..remove('provisionTarget'),
  );

  /// Last user-selected connection target. Persisted so a disconnect →
  /// connect (and a restart with a GC'd peer) redials the same server or
  /// region instead of auto-picking. Exactly one side is non-null by
  /// contract (see `selectTarget`); both null means Auto. [explicitTarget]
  /// records whether the pin came from a manual tap (constrains auto-failover
  /// to the region) or an auto-pick (failover may roam globally). Cleared with
  /// the device on logout or session revocation so it never leaks into the
  /// next login.
  Future<({String? regionId, String? serverId, bool explicitTarget})>
  lastTarget() async {
    final t = (await _doc())['lastTarget'];
    if (t is Map) {
      return (
        regionId: t['regionId'] is String ? t['regionId'] as String : null,
        serverId: t['serverId'] is String ? t['serverId'] as String : null,
        explicitTarget: t['explicit'] == true,
      );
    }
    return (regionId: null, serverId: null, explicitTarget: false);
  }

  /// Writes the whole target as one value, so `regionId`, `serverId` and the
  /// explicit flag always land together and can never be a mix of two calls.
  Future<void> setLastTarget({
    required String? regionId,
    required String? serverId,
    required bool explicitTarget,
  }) {
    assert(
      regionId == null || serverId == null,
      'a target pins at most one of regionId/serverId',
    );
    return _mutate(
      (d) => d['lastTarget'] = {
        'regionId': regionId,
        'serverId': serverId,
        'explicit': explicitTarget,
      },
    );
  }

  /// Last known-good dial params as a JSON string (see `DialParams.toJson`).
  /// Written on every successful tunnel start, read only by cold-start
  /// reconciliation to render an optimistic Connected state while the
  /// server truth (`GET …/config`) is still in flight or unreachable.
  /// Kept as an opaque string (never a model) so this store stays free of
  /// model imports; the controller owns encode/decode. Cleared with the
  /// device and on explicit disconnect (the tunnel is down, so a cached
  /// dial must never resurrect it).
  Future<String?> lastDialJson() async => _string(await _doc(), 'lastDial');
  Future<void> setLastDialJson(String v) => _mutate((d) => d['lastDial'] = v);
  Future<void> clearLastDial() => _mutate((d) => d.remove('lastDial'));

  /// Wipes the device identity with one atomic delete.
  ///
  /// The custom device name is identity, not a UI preference: leaving it
  /// behind would make the next account on this install silently inherit the
  /// previous user's name (see `_provision`). Because the whole identity is a
  /// single entry there is no sequence of partial deletes that can leave
  /// fragments behind: either the wipe lands or it throws. [allowLocalKey] is
  /// the one deliberate survivor (see [allowLocal]).
  ///
  /// The delete is queued behind every earlier mutation, so a target write
  /// fired before the wipe can never complete after it and resurrect the old
  /// account's identity.
  Future<void> clearDevice() async {
    final release = await _mutex.acquire('clear-device');
    try {
      await _s.delete(key: identityKey);
    } finally {
      release();
    }
  }

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
final deviceStoreProvider = Provider((_) => DeviceStore());
