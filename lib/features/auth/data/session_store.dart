import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage_options.dart';

/// Session secrets for the auth flow.
///
/// The auth controller depends on this (not the device identity graph).
/// The access token doubles as the VPN Dio bearer token.
///
/// The whole session lives in one JSON entry so a rotation can never land
/// half-written (a fresh access token paired with a stale refresh token, or
/// an access token with no expiry): a [FlutterSecureStorage] write is a
/// single keychain/keystore operation.
class SessionStore {
  static const sessionKey = 'boltmesh_session';

  final FlutterSecureStorage _s;
  const SessionStore([this._s = kSharedSecureStorage]);

  Future<
    ({String? access, String? refresh, DateTime? expiry, String? username})
  >
  _read() async {
    final raw = await _s.read(key: sessionKey);
    if (raw == null) {
      return (access: null, refresh: null, expiry: null, username: null);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final ms = int.tryParse('${decoded['expiry_ms']}');
        return (
          access: decoded['access'] as String?,
          refresh: decoded['refresh'] as String?,
          expiry: ms == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
          username: decoded['user'] as String?,
        );
      }
    } catch (_) {
      // A corrupt entry reads as no session; the auth gate re-authenticates.
    }
    return (access: null, refresh: null, expiry: null, username: null);
  }

  Future<String?> apiToken() async => (await _read()).access;

  /// Native sessions are always persistent: the refresh value lives in
  /// secure storage until Log Out or server-side revocation.
  Future<String?> refreshToken() async => (await _read()).refresh;

  Future<DateTime?> accessExpiry() async => (await _read()).expiry;

  Future<String?> authUsername() async => (await _read()).username;

  /// Replaces the stored session in one write. A null [refreshToken] or
  /// [username] clears that field (matching the previous per-key delete).
  Future<void> setAuth({
    required String accessToken,
    required DateTime expiresAt,
    String? refreshToken,
    String? username,
  }) => _s.write(
    key: sessionKey,
    value: jsonEncode({
      'access': accessToken,
      'expiry_ms': expiresAt.toUtc().millisecondsSinceEpoch,
      'refresh': ?refreshToken,
      'user': ?username,
    }),
  );

  Future<void> clearAuth() => _s.delete(key: sessionKey);
}

/// Shared session backing. Lives next to [SessionStore] (rather than in VPN
/// state) so the auth controller can read it without importing the VPN
/// provider graph, which itself reads auth for the 401 refresh hook.
final sessionStoreProvider = Provider((_) => const SessionStore());
