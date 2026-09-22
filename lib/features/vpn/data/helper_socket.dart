/// Transport to the privileged `boltmeshd` helper.
///
/// The Flutter process is unprivileged: it never runs `sudo`, `wg`, or
/// `wg-quick`, and never reads the WireGuard device. All of that lives behind
/// this socket (see `client/linux/boltmeshd/`).
library;

/// Default socket path, matching the systemd unit's `ListenStream`.
const helperSocketPath = '/run/boltmesh/boltmeshd.sock';

/// Raised when the helper cannot be reached or answers malformed data.
class HelperTransportException implements Exception {
  HelperTransportException(this.message);

  final String message;

  @override
  String toString() => 'HelperTransportException: $message';
}

/// One request/response exchange with the helper.
abstract class HelperSocket {
  /// True on platforms where the helper exists (Linux).
  bool get isSupported;

  /// Sends one request and returns the decoded response. Throws
  /// [HelperTransportException] when the daemon is unreachable.
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request);
}
