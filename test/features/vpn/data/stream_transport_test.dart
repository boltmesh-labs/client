import 'dart:convert';
import 'dart:io';

import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/stream_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A well-formed credential: every field the daemon validates at its exact
/// size, base64-encoded.
StreamTransport validCredential({List<String>? pins}) => StreamTransport(
  server: 'vpn.example.net:443',
  serverName: 'vpn.example.net',
  spkiPins: pins ?? [base64.encode(List<int>.filled(streamSPKISize, 0xaa))],
  psk: base64.encode(List<int>.filled(streamPSKSize, 0xbb)),
  clientId: base64.encode(List<int>.filled(streamClientIDSize, 0xcc)),
);

void main() {
  group('StreamTransport.isUsable', () {
    test('accepts a complete credential', () {
      expect(validCredential().isUsable, isTrue);
    });

    test('accepts several pins, for a node rotating its key', () {
      final pins = [
        base64.encode(List<int>.filled(streamSPKISize, 1)),
        base64.encode(List<int>.filled(streamSPKISize, 2)),
      ];
      expect(validCredential(pins: pins).isUsable, isTrue);
    });

    test('rejects an incomplete or malformed credential', () {
      // Every case mirrors the daemon's own validation: a descriptor this
      // accepts is one the helper will accept, so a rung is never selected
      // with credentials the daemon would refuse.
      final cases = <String, StreamTransport>{
        'no server': validCredential().copyWith(server: ''),
        'blank server': validCredential().copyWith(server: '   '),
        'no server name': validCredential().copyWith(serverName: ''),
        'no pins': validCredential(pins: const []),
        'pin not base64': validCredential(pins: ['not base64!!']),
        'pin wrong size': validCredential(
          pins: [base64.encode(List<int>.filled(20, 1))],
        ),
        'one bad pin among good ones': validCredential(
          pins: [
            base64.encode(List<int>.filled(streamSPKISize, 1)),
            base64.encode(List<int>.filled(8, 1)),
          ],
        ),
        'no psk': validCredential().copyWith(psk: ''),
        'psk wrong size': validCredential().copyWith(
          psk: base64.encode(List<int>.filled(16, 1)),
        ),
        'psk not base64': validCredential().copyWith(psk: 'not base64!!'),
        'no client id': validCredential().copyWith(clientId: ''),
        'client id wrong size': validCredential().copyWith(
          clientId: base64.encode(List<int>.filled(32, 1)),
        ),
      };
      cases.forEach((name, credential) {
        expect(credential.isUsable, isFalse, reason: name);
      });
    });

    test('an absent stream decodes to null, not a broken credential', () {
      final dial = DialParams.fromJson(const {
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
      });
      expect(dial.stream, isNull);
    });

    test('decodes the backend stream object field for field', () {
      final credential = validCredential();
      final dial = DialParams.fromJson({
        'id': 'dev-1',
        'assigned_ip': '10.8.0.5',
        'server_id': 'srv-1',
        'endpoint': '203.0.113.10',
        'wg_port': 51820,
        'wg_dns': '10.8.0.1',
        'wg_public_key': 'SRV',
        'stream': {
          'server': credential.server,
          'server_name': credential.serverName,
          'spki_sha256': credential.spkiPins,
          'psk': credential.psk,
          'client_id': credential.clientId,
        },
      });
      expect(dial.stream, credential);
    });
  });

  group('TunnelTransport', () {
    test('renders the helper transport spec', () {
      final credential = validCredential();
      final transport = TunnelTransport(
        listen: '127.0.0.1:51821',
        deliver: '127.0.0.1:51820',
        credential: credential,
      );

      // Field names and encodings must match protocol.TransportSpec exactly;
      // the daemon rejects anything else, and it validates before it binds.
      expect(transport.toSpecJson(), {
        'mode': 'stream',
        'listen': '127.0.0.1:51821',
        'deliver': '127.0.0.1:51820',
        'server': 'vpn.example.net:443',
        'server_name': 'vpn.example.net',
        'spki_sha256': credential.spkiPins,
        'psk': credential.psk,
        'client_id': credential.clientId,
      });
      expect(transport.listenPort, 51821);
      expect(transport.deliverPort, 51820);
    });

    test('rejects an address it cannot read a port out of', () {
      for (final bad in ['127.0.0.1', '127.0.0.1:0', '127.0.0.1:x', ':::0']) {
        final transport = TunnelTransport(
          listen: bad,
          deliver: '127.0.0.1:51820',
          credential: validCredential(),
        );
        expect(() => transport.listenPort, throwsArgumentError, reason: bad);
      }
    });

    test('toString does not leak the pre-shared key', () {
      final credential = validCredential();
      final transport = TunnelTransport(
        listen: '127.0.0.1:51821',
        deliver: '127.0.0.1:51820',
        credential: credential,
      );
      // A transport is logged on every start; the PSK must not ride along.
      expect(transport.toString(), isNot(contains(credential.psk)));
      expect(transport.toString(), contains('127.0.0.1:51821'));
    });
  });

  group('allocateLoopbackPorts', () {
    test('yields two distinct, non-zero loopback ports', () async {
      final ports = await allocateLoopbackPorts();
      expect(ports.listen, greaterThan(0));
      expect(ports.deliver, greaterThan(0));
      expect(ports.listen, lessThanOrEqualTo(65535));
      expect(ports.deliver, lessThanOrEqualTo(65535));
      // The kernel binds the bridge's listen address and the interface's own
      // listen port, so the same port twice would leave one of them refused.
      expect(ports.listen, isNot(ports.deliver));
    });

    test('each allocation is free at the moment it is handed out', () async {
      // The probe only proves the port was free when the socket closed; what
      // it must never do is hand back a port the kernel is already using.
      final ports = await allocateLoopbackPorts();
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        ports.listen,
      );
      addTearDown(socket.close);
      expect(socket.port, ports.listen);
    });
  });
}
