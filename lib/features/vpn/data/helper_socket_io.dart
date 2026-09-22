import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'helper_socket.dart';

/// True where a `boltmeshd` helper exists: Linux (Unix socket) and Windows
/// (named pipe).
bool get isHelperPlatformSupported => Platform.isLinux || Platform.isWindows;

HelperSocket createHelperSocket() {
  if (Platform.isWindows) return NativePipeHelperSocket();
  return UnixHelperSocket();
}

/// [HelperSocket] over a Unix domain socket with one connection per request.
///
/// A fresh connection per request keeps the transport stateless (no
/// interleaving, no half-closed socket to recover); a UDS connect is cheap
/// next to the ~10s health tick that drives these reads.
class UnixHelperSocket implements HelperSocket {
  UnixHelperSocket({
    this.path = helperSocketPath,
    this.connectTimeout = defaultConnectTimeout,
    this.readTimeout = defaultReadTimeout,
  });

  /// Upper bound on establishing the UDS connection. A UDS connect is
  /// normally instant; a full accept queue must still fail fast.
  static const defaultConnectTimeout = Duration(seconds: 5);

  /// Upper bound on the response read. Without it a daemon that accepts the
  /// connection but never answers would leave the read pending forever (and
  /// the socket undestroyed); on expiry the socket is torn down by `finally`.
  static const defaultReadTimeout = Duration(seconds: 10);

  final String path;

  /// Injectable for tests; see [defaultConnectTimeout].
  final Duration connectTimeout;

  /// Injectable for tests; see [defaultReadTimeout].
  final Duration readTimeout;

  @override
  bool get isSupported => Platform.isLinux;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) async {
    late final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(connectTimeout);
    } catch (e) {
      throw HelperTransportException('helper socket unavailable: $e');
    }

    try {
      socket.write('${jsonEncode(request)}\n');
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(readTimeout);
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw HelperTransportException('helper response is not an object');
      }
      return Map<String, dynamic>.from(decoded);
    } on HelperTransportException {
      rethrow;
    } on TimeoutException {
      throw HelperTransportException('helper response timed out');
    } catch (e) {
      throw HelperTransportException('helper request failed: $e');
    } finally {
      socket.destroy();
    }
  }
}

/// [HelperSocket] over the Windows named pipe, proxied through the runner's
/// native `com.boltmesh/helper` channel.
///
/// `dart:io` has no Windows named-pipe client, so `windows/runner/helper_pipe.cpp`
/// performs the CreateFile/WriteFile/ReadFile exchange and returns one
/// response line. The framing is identical to [UnixHelperSocket], so the
/// helper daemon serves both transports with the same code.
class NativePipeHelperSocket implements HelperSocket {
  NativePipeHelperSocket({MethodChannel? channel})
    : _channel = channel ?? defaultChannel;

  /// The app's helper channel, registered by `windows/runner/helper_pipe.cpp`.
  static const defaultChannel = MethodChannel('com.boltmesh/helper');

  final MethodChannel _channel;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) async {
    final String? response;
    try {
      response = await _channel.invokeMethod<String>(
        'exchange',
        jsonEncode(request),
      );
    } on MissingPluginException {
      throw HelperTransportException('helper pipe channel unavailable');
    } on PlatformException catch (e) {
      throw HelperTransportException(
        'helper request failed: ${e.message ?? e.code}',
      );
    }
    if (response == null) {
      throw HelperTransportException('helper returned no response');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response);
    } on FormatException catch (e) {
      throw HelperTransportException('helper response is not JSON: $e');
    }
    if (decoded is! Map) {
      throw HelperTransportException('helper response is not an object');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
