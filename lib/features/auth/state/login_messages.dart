import 'package:dio/dio.dart';

import '../../../core/dio_client.dart';

/// Login-screen copy for auth failures. 401 always means bad credentials
/// here (the login POST carries no token to expire). Unknown errors fall back
/// to a fixed sentence: a raw `e.toString()` can leak internals and is never
/// user-facing.
String loginMessage(Object e) {
  final err = asVpnError(e);
  if (err == null) {
    if (e is DioException && e.response == null) {
      return 'No network connection. Check your connection and retry.';
    }
    return _unknownLoginError;
  }
  if (err.statusCode == 401) {
    return 'Incorrect username, email, or password.';
  }
  if (err.statusCode == 429) {
    return 'Too many attempts. Try again shortly.';
  }
  return err.message;
}

const _unknownLoginError = 'Something went wrong. Please try again.';

/// Bounds and strips control characters from an OAuth `error` delivered on
/// the app callback URL. The callback is attacker-reachable on Android (any
/// app may register the `boltmesh://` scheme), so the value is bounded and
/// never rendered verbatim. Returns null when nothing usable remains.
String? sanitizeOauthError(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= 200 ? cleaned : cleaned.substring(0, 200);
}
