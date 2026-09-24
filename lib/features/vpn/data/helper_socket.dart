/// Transport to the privileged `boltmeshd` helper.
///
/// The Flutter process is unprivileged: it never runs `sudo`, `wg`,
/// `wg-quick`, or an elevated Windows service, and never reads the WireGuard
/// device. All of that lives behind this transport (see `boltmeshd/`).
library;

/// Default Unix socket path (Linux), matching the systemd unit's
/// `ListenStream`.
const helperSocketPath = '/run/boltmesh/boltmeshd.sock';

/// Default named pipe path (Windows), matching the daemon's default.
const helperPipePath = r'\\.\pipe\boltmesh\boltmeshd';

/// Raised when the helper cannot be reached or answers malformed data.
class HelperTransportException implements Exception {
  HelperTransportException(this.message);

  final String message;

  @override
  String toString() => 'HelperTransportException: $message';
}

/// One request/response exchange with the helper.
abstract class HelperSocket {
  /// True on platforms where the helper exists (Linux, Windows).
  bool get isSupported;

  /// Sends one request and returns the decoded response. Throws
  /// [HelperTransportException] when the daemon is unreachable.
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request);
}

/// Optional transport capability for deadline-aware exchanges.
///
/// [HelperSocket] intentionally keeps its original one-argument contract so
/// small injected test doubles and future transports remain source-compatible.
/// Production transports implement this interface so [HelperClient] can give
/// the transport the same deadline it uses for the caller. A transport that
/// does not implement it still gets a Future.timeout backstop from the client.
abstract class HelperSocketWithTimeout implements HelperSocket {
  /// Sends one request with a total exchange deadline. Implementations must
  /// close/cancel their underlying connection when the deadline expires, not
  /// merely return a timeout error to the Dart caller.
  Future<Map<String, dynamic>> exchangeWithTimeout(
    Map<String, dynamic> request, {
    required Duration timeout,
  });
}
