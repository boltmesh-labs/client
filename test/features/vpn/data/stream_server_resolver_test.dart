import 'dart:async';
import 'dart:io';

import 'package:boltmesh/features/vpn/data/stream_server_resolver_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveStreamServer', () {
    test('passes a literal IPv4 address through untouched', () async {
      final result = await resolveStreamServer(
        '203.0.113.9:443',
        lookup: (_) async => fail('a literal address must not be resolved'),
      );
      expect(result, '203.0.113.9:443');
    });

    test('passes a bracketed IPv6 literal through untouched', () async {
      final result = await resolveStreamServer(
        '[2001:db8::1]:443',
        lookup: (_) async => fail('a literal address must not be resolved'),
      );
      expect(result, '[2001:db8::1]:443');
    });

    test('prefers IPv4 when a host resolves to both families', () async {
      final result = await resolveStreamServer(
        'node.example:443',
        lookup: (_) async => [
          InternetAddress('2001:db8::1', type: InternetAddressType.IPv6),
          InternetAddress('203.0.113.9'),
        ],
      );
      expect(result, '203.0.113.9:443');
    });

    test('brackets an IPv6-only answer', () async {
      final result = await resolveStreamServer(
        'node.example:443',
        lookup: (_) async => [
          InternetAddress('2001:db8::1', type: InternetAddressType.IPv6),
        ],
      );
      expect(result, '[2001:db8::1]:443');
    });

    test('throws when a host resolves to nothing', () async {
      await expectLater(
        resolveStreamServer('node.example:443', lookup: (_) async => const []),
        throwsA(isA<SocketException>()),
      );
    });

    test('throws when the address has no port', () async {
      await expectLater(
        resolveStreamServer('node.example', lookup: (_) async => const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('bounds a lookup that never completes', () async {
      await expectLater(
        resolveStreamServer(
          'node.example:443',
          lookup: (_) => Completer<List<InternetAddress>>().future,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
