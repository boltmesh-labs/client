import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A PKCE S256 (verifier, challenge) pair for the native OAuth exchange.
///
/// The verifier never leaves the app. Its challenge is sent to the backend's
/// authorize endpoint and bound onto the single-use exchange code, so another
/// app that hijacks the `boltmesh://` callback cannot redeem a stolen code.
typedef PkcePair = ({String verifier, String challenge});

/// Generates a 43-character base64url verifier (32 random bytes, per
/// RFC 7636) and its S256 challenge. [random] is injectable for tests.
PkcePair generatePkcePair([Random? random]) {
  final rnd = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  final verifier = base64UrlEncode(bytes).replaceAll('=', '');
  final challenge = base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
  return (verifier: verifier, challenge: challenge);
}
