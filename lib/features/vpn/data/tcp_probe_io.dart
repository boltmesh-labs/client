import 'dart:async';
import 'dart:io';

/// TCP connect to [host]:[port] within [timeout]. Tri-state: true = the
/// handshake completed (the port is reachable), false = refused, timed out,
/// or unresolvable (unreachable), null = the probe itself errored in a way
/// that proves nothing (unknown — the caller fails open).
Future<bool?> tcpConnect(String host, int port, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout).timeout(
      timeout,
      onTimeout: () => throw TimeoutException('tcp probe timed out', timeout),
    );
    return true;
  } on TimeoutException {
    return false;
  } on SocketException {
    return false;
  } catch (_) {
    return null;
  } finally {
    try {
      await socket?.close();
    } catch (_) {}
  }
}
