import '../../../core/errors.dart';
import '../data/helper_client.dart';
import '../data/helper_socket.dart';

/// The reason to show for a failed tunnel operation.
///
/// The backend's own copy wins when it answered — [ApiException.message] is
/// written for users — and the helper is translated, because what it reports is
/// a diagnostic rather than an explanation:
///
///     HelperException(internal): obfuscated up: configure device:
///     IPC error -22: failed to set endpoint node.example.net:51820:
///     No such host is known.
///
/// That names the syscall that failed inside a privileged daemon, which is what
/// the log file is for and nothing a user can act on. The codes are few
/// ([protocol.Code*] in `boltmeshd/internal/protocol/protocol.go`) and each has
/// one next step, so the UI gets that instead.
///
/// Anything else is left exactly as it stands: every other error the VPN layer
/// raises is already a sentence written for the user (the identity guards in
/// `ConnectionController._startWith`, the unsupported-region refusal in
/// `ConnectionController._applyRung`), and flattening those into a generic
/// sentence would throw away better copy than it replaced.
String failureReason(ApiException? apiError, Object e) =>
    apiError?.message ?? _helperIssueText(e) ?? e.toString();

/// User-facing projection of the helper's two failure types, or null when [e] is
/// neither.
///
/// [HelperTransportException] — the daemon could not be reached at all — is the
/// same user-visible problem the `denied` stage reports (see
/// `ConnectionStage._deniedMessage`): this app is unprivileged, so a missing or
/// stopped helper service is something only the user can fix.
String? _helperIssueText(Object e) => switch (e) {
  HelperException(:final code) => switch (code) {
    // The daemon rejected the config the client sent. A fresh connect refetches
    // it from the backend, which is the only thing that can fix this.
    'bad_config' =>
      'The VPN configuration was rejected. Reconnect to fetch a fresh one.',
    // The daemon holds the privileged-operation slot (a previous up/down is
    // still running) or is shutting down.
    'unavailable' => 'The VPN helper is busy. Try again in a moment.',
    // Everything else the daemon can fail an `up` with: an endpoint it cannot
    // resolve, a driver it cannot pin, a network state it cannot apply.
    _ =>
      'The VPN tunnel could not start on this device. '
          'Check your connection and try again.',
  },
  HelperTransportException() =>
    "Can't reach the BoltMesh helper service. Make sure it is installed and "
        'running, then reconnect.',
  _ => null,
};
