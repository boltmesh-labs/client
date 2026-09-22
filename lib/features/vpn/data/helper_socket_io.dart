import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'helper_socket.dart';

bool get isHelperPlatformSupported => Platform.isLinux;

HelperSocket createHelperSocket() => UnixHelperSocket();

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
