import 'dart:convert';

import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Conformance against the backend's *verbatim* output.
///
/// The fixtures below are what `app/vpn/schemas` actually serializes — captured
/// from `VpnServerRegistrationOut.model_dump_json()` and
/// `build_device_dial_payload(...).model_dump_json(exclude_none=True)`, with the
/// random values replaced by fixed ones so the payload is stable.
///
/// Three independent implementations read these objects: this Dart model, the
/// agent's `RegistrationResponse`/peer-sync structs, and the agent's own
/// `config.ObfuscationDescriptor`. They are written in three languages against
/// three repos, so nothing but a fixture like this catches a rename. A drift here
/// would not fail any unit test on either side: the client would simply decode
/// `stream: null` and quietly never offer the rung.
void main() {
  group('the backend dial payload', () {
    test('decodes the rung list in order, one port and payload per rung', () {
      // The list is the whole contract: index order is the cost order, and each
      // entry carries the port its own device binds plus the parameters or
      // credential that rung needs. A rename or a moved field shows up here and
      // nowhere else, because the client's ladder reads only this.
      final dial = DialParams.fromJson(_dialPayload());
      expect(dial.advertisedRungs, [
        TransportRung.native,
        TransportRung.awg,
        TransportRung.stream,
      ]);
      expect(dial.transportFor(TransportRung.native)!.port, 51820);
      expect(dial.transportFor(TransportRung.awg)!.port, 51821);
      expect(dial.transportFor(TransportRung.stream)!.port, 443);
    });

    test('decodes the obfuscation parameters into a usable AWG conf', () {
      final dial = DialParams.fromJson(_dialPayload());
      final entry = dial.transportFor(TransportRung.awg)!;
      expect(entry.isComplete, isTrue);
      expect(entry.params!.isComplete, isTrue);
      expect(entry.params!.jc, 3);
      expect(entry.params!.jmin, 40);
      expect(entry.params!.h1, [10, 20]);
    });

    test('decodes the stream credential at the sizes the daemon enforces', () {
      final dial = DialParams.fromJson(_dialPayload());
      final credential = dial.transportFor(TransportRung.stream)!.credential;
      expect(credential, isNotNull);
      // isUsable is the only gate the ladder consults, so it has to agree with
      // the daemon's own validation of these same fields.
      expect(credential!.isUsable, isTrue);
      expect(credential.server, 'node-1.us-east-1.vpn.example.com:443');
      expect(credential.serverName, 'node-1.us-east-1.vpn.example.com');
      expect(credential.spkiPins, hasLength(1));
      // Decoded sizes, so a change to the daemon's constants is caught here
      // rather than at connect time.
      expect(base64.decode(credential.spkiPins.single), hasLength(32));
      expect(base64.decode(credential.psk), hasLength(32));
      expect(base64.decode(credential.clientId), hasLength(16));
    });

    test('the stream credential rides the dial payload, not the region list', () {
      // The PSK is a per-device secret and discovery is fetched by every client
      // of a region. If the backend ever moved it, this is what would catch it.
      final discovery = DiscoveryServer.fromJson(_discoveryPayload());
      expect(discovery.id, isNotEmpty);
      expect(
        jsonEncode(_discoveryPayload()).contains('psk'),
        isFalse,
        reason: 'region discovery must never carry a device credential',
      );
    });

    test('a backend serving only stock decodes to a native-only ladder', () {
      // The withholding, as the client sees it: a rung the node cannot serve is
      // simply absent from the list, which is the same thing as never having
      // offered it.
      final native = _dialPayload();
      native['transports'] = [
        {'rung': 'native', 'port': 51820},
      ];
      final dial = DialParams.fromJson(native);
      expect(dial.advertisedRungs, [TransportRung.native]);
      expect(dial.transportFor(TransportRung.awg), isNull);
      expect(dial.transportFor(TransportRung.stream), isNull);
    });
  });

  group('the backend stream_ingress descriptor', () {
    // The node reads this, not the client; it is parsed here only to pin the
    // shape the agent's Go struct unmarshals, since that is the third reader.
    test('carries a port and a name, and no key material', () {
      final registration =
          jsonDecode(_registrationPayload()) as Map<String, dynamic>;
      final ingress = registration['stream_ingress'] as Map<String, dynamic>;
      expect(ingress['enabled'], isTrue);
      expect(ingress['listen_port'], 443);
      expect(ingress['server_name'], 'node-1.us-east-1.vpn.example.com');
      // The node mints its own identity, so a certificate or key appearing here
      // would mean the control plane had started storing a TLS private key.
      expect(ingress.containsKey('certificate_pem'), isFalse);
      expect(ingress.containsKey('private_key_pem'), isFalse);
    });
  });
}

/// The backend's `VpnServerRegistrationOut.model_dump_json()` output, with the
/// node id fixed.
String _registrationPayload() => jsonEncode({
  'node_token': 'tok',
  'token_expires_in': 900,
  'tunnel_ip': '10.254.0.1/16',
  'node_id': '72e5b789-7329-4867-9f4b-a5fa16d1ff42',
  'name': 'node-1',
  'region': 'us-east-1',
  'region_name': 'US East',
  'region_country': 'US',
  'os': 'rocky',
  'public_ip': '198.51.100.2',
  'endpoint': 'node-1.us-east-1.vpn.example.com',
  'wg_port': 51820,
  'wg_dns': '10.254.0.1',
  'amnezia_port': 51821,
  'amnezia_tunnel_ip': '10.255.0.1/16',
  'tcp_port': 443,
  // The node's own copy of the obfuscation descriptor. It keeps the mode/params
  // shape even though the device-facing dial payload no longer has one: the agent
  // reads it to decide which data plane to run, and a descriptor is not a rung
  // list. The port and the overlay address are separate named fields beside it.
  'obfuscation': {'mode': 'awg', 'params': _awgParams},
  'stream_ingress': {
    'enabled': true,
    'listen_port': 443,
    'server_name': 'node-1.us-east-1.vpn.example.com',
  },
});

/// The backend's `build_device_dial_payload(...).model_dump_json(
/// exclude_none=True)` output, with the generated ids fixed.
Map<String, dynamic> _dialPayload() =>
    jsonDecode(_dialJson) as Map<String, dynamic>;

String get _dialJson => jsonEncode({
  'id': 'c392fc0a-b83c-4a46-9da5-6be4923088e6',
  'user_id': 'ad63445e-e6d6-4e34-a41c-afdaf764d263',
  'subscription_id': null,
  'name': 'laptop',
  'platform': 'linux',
  'is_active': true,
  'disabled_at': null,
  'created_at': '2026-10-01T09:29:08.130874Z',
  'updated_at': null,
  'peer_id': 'e6a75c53-7018-40d6-b579-69ceb979a2f2',
  'client_public_key': 'p' * 44,
  'assigned_ip': '10.254.0.2/32',
  'awg_assigned_ip': '10.255.0.2/32',
  'awg_dns': '10.255.0.1',
  'server_id': 'd75360bc-ba72-4cc0-86da-5ef25e3cda48',
  'server_name': 'node-1',
  'endpoint': 'node-1.us-east-1.vpn.example.com',
  'wg_port': 51820,
  'wg_dns': '10.254.0.1',
  'wg_public_key': 's' * 44,
  'transports': [
    {'rung': 'native', 'port': 51820},
    {'rung': 'awg', 'port': 51821, 'params': _awgParams},
    {
      'rung': 'stream',
      'port': 443,
      'credential': {
        'server': 'node-1.us-east-1.vpn.example.com:443',
        'server_name': 'node-1.us-east-1.vpn.example.com',
        // base64 of 32 × 0xAA
        'spki_sha256': ['qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo='],
        // base64 of bytes 0..31
        'psk': 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
        // base64 of 16 zero bytes
        'client_id': 'AAAAAAAAAAAAAAAAAAAAAA==',
      },
    },
  ],
});

Map<String, dynamic> _discoveryPayload() => {
  'id': 'd75360bc-ba72-4cc0-86da-5ef25e3cda48',
  'name': 'node-1',
  'endpoint': 'node-1.us-east-1.vpn.example.com',
  'wg_port': 51820,
  'wg_dns': '10.254.0.1',
  'wg_public_key': 's' * 44,
  'status': 'online',
  'active_peers': 3,
};

Map<String, dynamic> get _awgParams => {
  'jc': 3,
  'jmin': 40,
  'jmax': 70,
  's1': 20,
  's2': 25,
  's3': 30,
  's4': 35,
  'h1': [10, 20],
  'h2': [30, 40],
  'h3': [50, 60],
  'h4': [70, 80],
};
