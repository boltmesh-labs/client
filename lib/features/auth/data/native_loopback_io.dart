import 'dart:io';

/// Binds an ephemeral loopback port and releases it, returning the port
/// number. The OAuth plugin binds its own listener on the advertised port,
/// so a small reuse race is inherent — a conflict surfaces as a login
/// error the user can retry.
Future<int> findFreeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    return socket.port;
  } finally {
    await socket.close();
  }
}
