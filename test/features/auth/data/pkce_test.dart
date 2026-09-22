import 'dart:convert';
import 'dart:math';

import 'package:boltmesh/features/auth/data/pkce.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates an RFC 7636 verifier and its S256 challenge', () {
    final pair = generatePkcePair(Random(1));
    expect(pair.verifier.length, 43);
    expect(pair.verifier, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    final expected = base64UrlEncode(
      sha256.convert(utf8.encode(pair.verifier)).bytes,
    ).replaceAll('=', '');
    expect(pair.challenge, expected);
    expect(pair.challenge.length, 43);
  });

  test('uses fresh randomness by default', () {
    expect(generatePkcePair().verifier, isNot(generatePkcePair().verifier));
  });
}
