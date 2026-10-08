import 'package:boltmesh/features/vpn/data/tcp_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTcpHostPort', () {
    test('host:port splits', () {
      expect(parseTcpHostPort('vpn.example.net:443'), ('vpn.example.net', 443));
      expect(parseTcpHostPort('203.0.113.10:8443'), ('203.0.113.10', 8443));
    });

    test('a bare host takes the default port', () {
      expect(parseTcpHostPort('vpn.example.net'), ('vpn.example.net', 443));
      expect(parseTcpHostPort('vpn.example.net', defaultPort: 8443), (
        'vpn.example.net',
        8443,
      ));
    });

    test('bracketed v6 splits, bare v6 keeps the default port', () {
      expect(parseTcpHostPort('[::1]:8443'), ('::1', 8443));
      expect(parseTcpHostPort('::1'), ('::1', 443));
    });

    test('unparseable values are null', () {
      expect(parseTcpHostPort(''), isNull);
      expect(parseTcpHostPort('   '), isNull);
      expect(parseTcpHostPort('host:0'), isNull);
      expect(parseTcpHostPort('host:65536'), isNull);
      expect(parseTcpHostPort('host:notaport'), isNull);
      expect(parseTcpHostPort('[::1]:0'), isNull);
      expect(parseTcpHostPort('has space:443'), isNull);
      expect(parseTcpHostPort('host', defaultPort: 0), isNull);
    });

    test('surrounding whitespace is trimmed', () {
      expect(parseTcpHostPort('  vpn.example.net:443  '), (
        'vpn.example.net',
        443,
      ));
    });
  });

  group('SocketTcpProbe.check', () {
    test('passes the injected result through', () async {
      expect(
        await SocketTcpProbe(connect: (_, _, _) async => true).check('h', 443),
        isTrue,
      );
      expect(
        await SocketTcpProbe(connect: (_, _, _) async => false).check('h', 443),
        isFalse,
      );
      expect(
        await SocketTcpProbe(connect: (_, _, _) async => null).check('h', 443),
        isNull,
      );
    });

    test('forwards host, port and timeout', () async {
      var seenHost = '';
      var seenPort = 0;
      var seenTimeout = Duration.zero;
      final probe = SocketTcpProbe(
        connect: (host, port, timeout) async {
          seenHost = host;
          seenPort = port;
          seenTimeout = timeout;
          return true;
        },
      );

      await probe.check(
        'vpn.example.net',
        8443,
        timeout: const Duration(seconds: 2),
      );

      expect(seenHost, 'vpn.example.net');
      expect(seenPort, 8443);
      expect(seenTimeout, const Duration(seconds: 2));
    });

    test('invalid targets are unknown without connecting', () async {
      var calls = 0;
      final probe = SocketTcpProbe(
        connect: (_, _, _) async {
          calls++;
          return true;
        },
      );

      expect(await probe.check('', 443), isNull);
      expect(await probe.check('h', 0), isNull);
      expect(await probe.check('h', 65536), isNull);
      expect(calls, 0);
    });

    test('a throwing connector is unknown, never a throw', () async {
      final probe = SocketTcpProbe(
        connect: (_, _, _) async => throw StateError('blew up'),
      );

      expect(await probe.check('h', 443), isNull);
    });
  });
}
