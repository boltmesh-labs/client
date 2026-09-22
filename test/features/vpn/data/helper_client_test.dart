import 'dart:async';
import 'dart:io';

import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedSocket implements HelperSocket {
  _ScriptedSocket(this.responder);

  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) responder;
  final List<Map<String, dynamic>> requests = [];

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) {
    requests.add(request);
    return responder(request);
  }
}

Map<String, dynamic> _ok(Map<String, dynamic> status) => {
  'v': helperProtocolVersion,
  'id': '1',
  'ok': true,
  'status': status,
};

void main() {
  test('ping sends the protocol version and decodes status', () async {
    final socket = _ScriptedSocket(
      (_) async => _ok({
        'interface': 'boltmesh0',
        'up': true,
        'stage': 'connected',
        'rxBytes': 10,
        'txBytes': 20,
      }),
    );
    final client = HelperClient(socket: socket);

    final status = await client.ping();

    expect(socket.requests.single['v'], helperProtocolVersion);
    expect(socket.requests.single['op'], 'ping');
    expect(status.interfaceName, 'boltmesh0');
    expect(status.up, isTrue);
    expect(status.rxBytes, 10);
    expect(status.txBytes, 20);
  });

  test('up carries the config text', () async {
    final socket = _ScriptedSocket((_) async => _ok({'up': false}));
    final client = HelperClient(socket: socket);

    await client.up('[Interface]\nPrivateKey = x\n');

    expect(socket.requests.single['op'], 'up');
    expect(socket.requests.single['config'], '[Interface]\nPrivateKey = x\n');
  });

  test('error responses raise HelperException with the daemon code', () async {
    final socket = _ScriptedSocket(
      (_) async => {
        'v': helperProtocolVersion,
        'id': '1',
        'ok': false,
        'error': {'code': 'bad_config', 'message': 'nope'},
      },
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.up('bad'),
      throwsA(
        isA<HelperException>()
            .having((e) => e.code, 'code', 'bad_config')
            .having((e) => e.message, 'message', 'nope'),
      ),
    );
  });

  test('protocol version mismatch is rejected', () async {
    final socket = _ScriptedSocket(
      (_) async => {'v': helperProtocolVersion + 1, 'id': '1', 'ok': true},
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.ping(),
      throwsA(
        isA<HelperException>().having((e) => e.code, 'code', 'bad_request'),
      ),
    );
  });

  test('a response without status is rejected', () async {
    final socket = _ScriptedSocket(
      (_) async => {'v': helperProtocolVersion, 'id': '1', 'ok': true},
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(isA<HelperException>().having((e) => e.code, 'code', 'internal')),
    );
  });

  test(
    'lastHandshake converts epoch seconds to UTC, 0 means unknown',
    () async {
      final socket = _ScriptedSocket(
        (_) async => _ok({'up': true, 'lastHandshake': 1718000000}),
      );
      final client = HelperClient(socket: socket);

      final status = await client.status();

      expect(
        status.lastHandshake,
        DateTime.fromMillisecondsSinceEpoch(1718000000 * 1000, isUtc: true),
      );

      final noHandshake = _ScriptedSocket(
        (_) async => _ok({'up': true, 'lastHandshake': 0}),
      );
      expect(
        await HelperClient(socket: noHandshake)
            .status()
            .then((s) => s.lastHandshake),
        isNull,
      );
    },
  );

  test('concurrent status reads share one exchange', () async {
    var calls = 0;
    final completer = Completer<Map<String, dynamic>>();
    final socket = _ScriptedSocket((_) {
      calls++;
      return completer.future;
    });
    final client = HelperClient(socket: socket);

    // The health tick issues these three back to back before the first
    // socket round-trip resolves; they must collapse into one request.
    final a = client.status();
    final b = client.status();
    final c = client.status();
    expect(identical(a, b), isTrue);
    expect(identical(b, c), isTrue);

    completer.complete(_ok({'up': true}));
    await Future.wait([a, b, c]);
    expect(calls, 1);

    // A later read is not served from the settled cache.
    await client.status();
    expect(calls, 2);
  });

  test('a wedged status call times out and does not poison later reads', () async {
    var calls = 0;
    final socket = _ScriptedSocket((_) {
      calls++;
      return Completer<Map<String, dynamic>>().future;
    });
    final client = HelperClient(
      socket: socket,
      callTimeout: const Duration(milliseconds: 20),
    );

    final a = client.status();
    final b = client.status();
    expect(identical(a, b), isTrue);

    // The backstop settles the shared future as a transport failure...
    await expectLater(a, throwsA(isA<HelperTransportException>()));
    await expectLater(b, throwsA(isA<HelperTransportException>()));
    // Let the in-flight marker clear before the next read.
    await Future<void>.delayed(Duration.zero);
    // ...so a later read starts a fresh exchange instead of reusing the wedge.
    await expectLater(
      client.status(),
      throwsA(isA<HelperTransportException>()),
    );
    expect(calls, 2);
  });

  test('helperProtocolVersion matches the Go daemon constant', () {
    final source = File('boltmeshd/internal/protocol/protocol.go')
        .readAsStringSync();
    final match = RegExp(
      r'^const Version\s*=\s*(\d+)\s*$',
      multiLine: true,
    ).firstMatch(source);
    expect(match, isNotNull, reason: 'protocol.Version not found');
    expect(int.parse(match!.group(1)!), helperProtocolVersion);
  });
}
