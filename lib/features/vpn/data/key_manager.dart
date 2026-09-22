import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Local X25519 (Curve25519) keypair.
///
/// Backend contract (backend/app/vpn/schemas/fields.py `validate_wg_key`):
/// public key must be standard base64 decoding to exactly 32 bytes
/// (44 chars with padding). The private key is base64 of the 32-byte
/// seed and never leaves the device.
class Keypair {
  final String privateKey;
  final String publicKey;
  const Keypair(this.privateKey, this.publicKey);
}

class KeyManager {
  final X25519 _algo = X25519();

  Future<Keypair> generate() async {
    final pair = await _algo.newKeyPair();
    final pub = await pair.extractPublicKey();
    final privBytes = await pair.extractPrivateKeyBytes();
    return Keypair(base64Encode(privBytes), base64Encode(pub.bytes));
  }
}
