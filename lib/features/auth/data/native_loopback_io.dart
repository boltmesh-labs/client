import 'dart:io';

/// Binds an ephemeral loopback port and releases it, returning the port
/// number. The OAuth plugin binds its own listener on the advertised port,
/// so a small reuse race is inherent. The auth controller retries once when
/// that hand-off loses the race.
/// Whether [error] is the expected race where the ephemeral port selected for
/// the OAuth callback was claimed before the plugin could bind it.
bool isLoopbackBindFailure(Object error) {
  if (error is! SocketException) return false;
  final code = error.osError?.errorCode;
  return code == 98 || // Linux EADDRINUSE
      code == 48 || // macOS EADDRINUSE
      code == 10048 || // Windows WSAEADDRINUSE
      error.message.toLowerCase().contains('address already in use');
}

Future<int> findFreeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    return socket.port;
  } finally {
    await socket.close();
  }
}
