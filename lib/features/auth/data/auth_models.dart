// Session tokens from backend/app/auth/routers/session.py.
//
// Login/refresh return `TokenOut` JSON
// `{access_token, token_type, expires_in, refresh_expires_in?}` while the
// refresh JWT itself travels in a `Set-Cookie: refresh_token=...` header
// (native has no cookie jar, so AuthApi forwards it manually).

import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_models.freezed.dart';

@freezed
abstract class AuthTokens with _$AuthTokens {
  /// Skew subtracted from the server `expires_in` so proactive refresh
  /// fires before the access token actually lapses.
  static const expirySkew = Duration(seconds: 60);

  const factory AuthTokens({
    required String accessToken,
    required DateTime expiresAt,
    String? refreshToken,
    int? refreshExpiresIn,
  }) = _AuthTokens;

  /// Parses a `TokenOut` body. Throws [FormatException] without an
  /// access token so callers fail loudly instead of storing half a session.
  static AuthTokens fromLogin(
    Map<String, dynamic> json, {
    String? refreshToken,
    DateTime? now,
  }) {
    final access = json['access_token'] as String?;
    if (access == null || access.isEmpty) {
      throw const FormatException('Login response has no access_token.');
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 900;
    final refreshExpires = (json['refresh_expires_in'] as num?)?.toInt();
    return AuthTokens(
      accessToken: access,
      expiresAt: (now ?? DateTime.now())
          .add(Duration(seconds: expiresIn))
          .subtract(expirySkew),
      refreshToken: refreshToken,
      refreshExpiresIn: refreshExpires,
    );
  }
}
