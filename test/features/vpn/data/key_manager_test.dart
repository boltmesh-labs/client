import 'dart:convert';

import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KeyManager.generate', () {
    // The backend rejects anything that is not exactly 32 bytes of standard
    // base64 (`validate_wg_key`), so a keypair that fails this is refused at
    // provision time with a confusing 422. This is the contract.
    test('produces keys the backend accepts', () async {
      final pair = await KeyManager().generate();

      final pub = base64Decode(pair.publicKey);
      expect(pub.length, 32);
      // 32 bytes base64-encodes to 44 chars including padding.
      expect(pair.publicKey.length, 44);

      final priv = base64Decode(pair.privateKey);
      expect(priv.length, 32);
    });

    test('the public key is the private key pair\'s public half', () async {
      // A mismatch here would provision a peer the server can never
      // handshake, so the two halves are verified against each other rather
      // than only checked for shape.
      final km = KeyManager();
      final generated = await km.generate();

      final derived = await X25519().newKeyPairFromSeed(
        base64Decode(generated.privateKey),
      );
      final derivedPub = await derived.extractPublicKey();

      expect(derivedPub.bytes, base64Decode(generated.publicKey));
    });

    test('each call yields a fresh keypair', () async {
      // The backend 409s on key reuse, and the controller binds a fresh peer
      // per connect/switch, so a repeating key would be a real defect.
      final km = KeyManager();
      final a = await km.generate();
      final b = await km.generate();

      expect(a.publicKey, isNot(b.publicKey));
      expect(a.privateKey, isNot(b.privateKey));
    });
  });
}
