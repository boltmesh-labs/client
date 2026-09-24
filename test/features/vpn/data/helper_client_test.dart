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

class _TimedSocket implements HelperSocketWithTimeout {
  _TimedSocket(this.responder);

  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic> request,
    Duration timeout,
  )
  responder;
  Duration? receivedTimeout;

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) =>
      responder(request, const Duration(seconds: 10));

  @override
  Future<Map<String, dynamic>> exchangeWithTimeout(
    Map<String, dynamic> request, {
    required Duration timeout,
  }) {
    receivedTimeout = timeout;
    return responder(request, timeout);
  }
}

/// A complete, well-formed status object. The client validates the full
/// schema, so partial fixtures are no longer accepted.
Map<String, dynamic> _status({
  bool up = true,
  String stage = 'connected',
  int rx = 0,
  int tx = 0,
  int handshake = 0,
}) => {
  'interface': 'boltmesh0',
  'up': up,
  'stage': stage,
  'rxBytes': rx,
  'txBytes': tx,
  'lastHandshake': handshake,
};

Map<String, dynamic> _ok(
  Object? id,
  Map<String, dynamic> status, {
  List<String>? caps,
}) => {
  'v': helperProtocolVersion,
  'id': id,
  'ok': true,
  'status': status,
  'caps': ?caps,
};

/// A responder that echoes the request id, like the daemon.
Future<Map<String, dynamic>> Function(Map<String, dynamic>) _reply(
  Map<String, dynamic> Function(Object? id) build,
) =>
    (req) async => build(req['id']);

void main() {
  test(
    'ping sends the protocol version, id and caps, then decodes status',
    () async {
      final socket = _ScriptedSocket(
        _reply(
          (id) => _ok(id, _status(rx: 10, tx: 20), caps: helperCapabilities),
        ),
      );
      final client = HelperClient(socket: socket);

      final status = await client.ping();

      expect(socket.requests.single['v'], helperProtocolVersion);
      expect(socket.requests.single['op'], 'ping');
      expect(socket.requests.single['id'], isA<String>());
      expect(socket.requests.single['caps'], helperCapabilities);
      expect(status.interfaceName, 'boltmesh0');
      expect(status.up, isTrue);
      expect(status.rxBytes, 10);
      expect(status.txBytes, 20);
      expect(client.capabilities, containsAll(helperCapabilities));
    },
  );

  test('up carries the config text', () async {
    final socket = _ScriptedSocket(
      _reply((id) => _ok(id, _status(up: false, stage: 'disconnected'))),
    );
    final client = HelperClient(socket: socket);

    await client.up('[Interface]\nPrivateKey = x\n');

    expect(socket.requests.single['op'], 'up');
    expect(socket.requests.single['config'], '[Interface]\nPrivateKey = x\n');
  });

  test('error responses raise HelperException with the daemon code', () async {
    final socket = _ScriptedSocket(
      _reply(
        (id) => {
          'v': helperProtocolVersion,
          'id': id,
          'ok': false,
          'error': {'code': 'bad_config', 'message': 'nope'},
        },
      ),
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
      _reply((id) => {'v': helperProtocolVersion + 1, 'id': id, 'ok': true}),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.ping(),
      throwsA(
        isA<HelperException>().having((e) => e.code, 'code', 'bad_request'),
      ),
    );
  });

  test('a mismatched response id is rejected', () async {
    final socket = _ScriptedSocket(
      _reply((_) => _ok('not-the-request-id', _status())),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('id mismatch'),
        ),
      ),
    );
  });

  test('a response without status is rejected', () async {
    final socket = _ScriptedSocket(
      _reply((id) => {'v': helperProtocolVersion, 'id': id, 'ok': true}),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(isA<HelperException>().having((e) => e.code, 'code', 'internal')),
    );
  });

  test('ok must be a bool', () async {
    final socket = _ScriptedSocket(
      _reply((id) => {'v': helperProtocolVersion, 'id': id, 'ok': 'yes'}),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('missing ok'),
        ),
      ),
    );
  });

  test('a success carrying an error is rejected', () async {
    final socket = _ScriptedSocket(
      _reply(
        (id) => {
          'v': helperProtocolVersion,
          'id': id,
          'ok': true,
          'status': _status(),
          'error': {'code': 'internal', 'message': 'x'},
        },
      ),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('success carries an error'),
        ),
      ),
    );
  });

  test('a failure carrying a status is rejected', () async {
    final socket = _ScriptedSocket(
      _reply(
        (id) => {
          'v': helperProtocolVersion,
          'id': id,
          'ok': false,
          'error': {'code': 'internal', 'message': 'x'},
          'status': _status(),
        },
      ),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('error carries a status'),
        ),
      ),
    );
  });

  test('a malformed error object is rejected', () async {
    final socket = _ScriptedSocket(
      _reply(
        (id) => {
          'v': helperProtocolVersion,
          'id': id,
          'ok': false,
          'error': {'code': 7},
        },
      ),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('malformed'),
        ),
      ),
    );
  });

  test('a status with a mistyped or missing field is rejected', () async {
    final socket = _ScriptedSocket(
      _reply(
        (id) => _ok(id, {
          'interface': 'boltmesh0',
          'up': true,
          'stage': 'connected',
          'lastHandshake': 0,
          'txBytes': 0,
          // rxBytes intentionally missing.
        }),
      ),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('malformed'),
        ),
      ),
    );
  });

  test('a stage outside the helper contract is rejected', () async {
    // The daemon only reports connected/connecting/disconnected. A mystery
    // stage must never be decoded (and then mapped to connected via `up`),
    // which would suppress tunnel-death detection.
    final socket = _ScriptedSocket(
      _reply((id) => _ok(id, _status(stage: 'mystery'))),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.status(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('malformed'),
        ),
      ),
    );
  });

  test('malformed caps are rejected', () async {
    final socket = _ScriptedSocket(
      _reply((id) => _ok(id, _status(), caps: const ['ok', ''])),
    );
    final client = HelperClient(socket: socket);

    expect(
      () => client.ping(),
      throwsA(
        isA<HelperException>().having(
          (e) => e.message,
          'message',
          contains('caps are malformed'),
        ),
      ),
    );
  });

  test(
    'lastHandshake converts epoch seconds to UTC, 0 means unknown',
    () async {
      final socket = _ScriptedSocket(
        _reply((id) => _ok(id, _status(handshake: 1718000000))),
      );
      final client = HelperClient(socket: socket);

      final status = await client.status();

      expect(
        status.lastHandshake,
        DateTime.fromMillisecondsSinceEpoch(1718000000 * 1000, isUtc: true),
      );

      final noHandshake = _ScriptedSocket(_reply((id) => _ok(id, _status())));
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
    final socket = _ScriptedSocket((req) {
      calls++;
      if (calls == 1) return completer.future;
      return Future.value(_ok(req['id'], _status()));
    });
    final client = HelperClient(socket: socket);

    // The health tick issues these three back to back before the first
    // socket round-trip resolves; they must collapse into one request.
    final a = client.status();
    final b = client.status();
    final c = client.status();
    expect(identical(a, b), isTrue);
    expect(identical(b, c), isTrue);

    completer.complete(_ok('1', _status()));
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

  test('a retry waits for the previous raw mutation exchange', () async {
    var calls = 0;
    final firstExchange = Completer<Map<String, dynamic>>();
    final socket = _ScriptedSocket((request) {
      calls++;
      if (calls == 1) return firstExchange.future;
      return Future.value(_ok(request['id'], _status()));
    });
    final client = HelperClient(
      socket: socket,
      callTimeout: const Duration(milliseconds: 100),
    );

    final first = client.down(timeout: const Duration(milliseconds: 20));
    final retry = client.down(timeout: const Duration(milliseconds: 100));
    await expectLater(first, throwsA(isA<HelperTransportException>()));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: 'retry must wait for the first raw exchange');

    firstExchange.complete(_ok('1', _status()));
    await retry;
    expect(calls, 2);
  });

  test(
    'forwards the shorter operation deadline to a timed transport',
    () async {
      final socket = _TimedSocket(
        (request, _) async => _ok(request['id'], _status()),
      );
      final client = HelperClient(socket: socket);

      await client.down(timeout: const Duration(seconds: 3));

      expect(socket.receivedTimeout, const Duration(seconds: 3));
    },
  );

  test(
    'does not let a test callTimeout extend a shipped operation budget',
    () async {
      final socket = _TimedSocket(
        (request, _) async => _ok(request['id'], _status()),
      );
      final client = HelperClient(
        socket: socket,
        callTimeout: const Duration(milliseconds: 20),
      );

      await client.ping(timeout: const Duration(seconds: 3));

      expect(socket.receivedTimeout, const Duration(milliseconds: 20));
    },
  );

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

  test('helperCapabilities are declared by the Go daemon', () {
    final source = File('boltmeshd/internal/protocol/protocol.go')
        .readAsStringSync();
    for (final cap in helperCapabilities) {
      expect(
        source,
        contains('"$cap"'),
        reason: '$cap is not declared in protocol.go',
      );
    }
  });
}
