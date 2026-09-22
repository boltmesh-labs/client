import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/data/helper_socket_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _unix = InternetAddressType.unix;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsUnixSockets = Platform.isLinux || Platform.isMacOS;

  group(
    'UnixHelperSocket',
    () {
      late Directory dir;
      late String path;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('boltmesh-helper-socket');
        path = '${dir.path}/boltmeshd.sock';
      });

      tearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      Future<ServerSocket> serve(
        Future<void> Function(Socket socket) handler,
      ) async {
        final server = await ServerSocket.bind(
          InternetAddress(path, type: _unix),
          0,
        );
        server.listen((socket) => unawaited(handler(socket)));
        addTearDown(server.close);
        return server;
      }

      test('exchanges one newline-delimited JSON request/response', () async {
        await serve((socket) async {
          final line = await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first;
          final request = jsonDecode(line) as Map<String, dynamic>;
          socket.write('${jsonEncode({'ok': true, 'op': request['op']})}\n');
          await socket.flush();
          await socket.close();
        });

        final socket = UnixHelperSocket(path: path);

        expect(await socket.exchange({'op': 'ping'}), {
          'ok': true,
          'op': 'ping',
        });
      });

      test('a non-object response is a transport failure', () async {
        await serve((socket) async {
          await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first;
          socket.write('"not-an-object"\n');
          await socket.flush();
          await socket.close();
        });

        expect(
          () => UnixHelperSocket(path: path).exchange({'op': 'ping'}),
          throwsA(isA<HelperTransportException>()),
        );
      });

      test('an unreachable socket path is a transport failure', () async {
        expect(
          () =>
              UnixHelperSocket(path: '${dir.path}/missing.sock')
                  .exchange({'op': 'ping'}),
          throwsA(isA<HelperTransportException>()),
        );
      });

      test('a daemon that never answers times out', () async {
        await serve((socket) async {
          await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first;
          // Hold the connection open without answering.
          await socket.done;
        });

        expect(
          () => UnixHelperSocket(
            path: path,
            readTimeout: const Duration(milliseconds: 50),
          ).exchange({'op': 'ping'}),
          throwsA(
            isA<HelperTransportException>().having(
              (e) => e.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
      });
    },
    skip: supportsUnixSockets
        ? false
        : 'Unix domain sockets are unsupported on this platform',
  );

  test('isSupported tracks the host platform', () {
    expect(UnixHelperSocket().isSupported, Platform.isLinux);
  });

  test('createHelperSocket builds a supported instance on Linux', () {
    if (!Platform.isLinux) return;
    expect(createHelperSocket(), isA<HelperSocket>());
    expect(isHelperPlatformSupported, isTrue);
  });

  group('NativePipeHelperSocket', () {
    const channel = MethodChannel('test/helper');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('exchanges a JSON request/response over the channel', () async {
      String? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'exchange');
        sent = call.arguments as String;
        return jsonEncode({'ok': true, 'op': 'ping'});
      });

      final socket = NativePipeHelperSocket(channel: channel);
      final response = await socket.exchange({'op': 'ping'});

      expect(jsonDecode(sent!), {'op': 'ping'});
      expect(response, {'ok': true, 'op': 'ping'});
    });

    test('a missing handler is a transport failure', () {
      final socket = NativePipeHelperSocket(
        channel: const MethodChannel('test/missing'),
      );
      expect(
        () => socket.exchange({'op': 'ping'}),
        throwsA(isA<HelperTransportException>()),
      );
    });

    test('a non-object response is a transport failure', () {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => '"not-an-object"',
      );
      final socket = NativePipeHelperSocket(channel: channel);
      expect(
        () => socket.exchange({'op': 'ping'}),
        throwsA(isA<HelperTransportException>()),
      );
    });
  });
}
