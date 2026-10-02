import 'package:flutter/foundation.dart';

import 'log_file.dart';

/// Minimal logger for the VPN connect flow.
///
/// Two sinks, deliberately different in reach:
///
///  * The console ([debugPrint]) is gated on [kDebugMode], so a release build
///    stays quiet in the terminal.
///  * Errors are additionally persisted to a rotating file under the user's
///    application-support directory, in every build mode.
///
/// The file sink exists because the console gate alone makes release builds
/// undiagnosable. A desktop app's stdout is discarded when it is launched from
/// Explorer or a service session, so a transport failure would otherwise leave
/// no trace at all — and `dio_client` deliberately keeps its user-facing copy
/// generic ("No network connection.") on the assumption that the OS-level detail
/// lands in a log line. In release that line does not exist, so every distinct
/// cause (DNS, refused, TLS handshake, proxy) collapses into one string the
/// user can report and nobody can act on.
///
/// Never pass secrets here — use [redact] for ids/keys. The file sink persists
/// what the console would have shown, so that rule now has a longer life than
/// the console session did.
class AppLog {
  const AppLog._();

  static void info(String message) {
    if (kDebugMode) debugPrint('[BoltMesh] $message');
  }

  /// Logs a failure to the console in debug builds and, in every build mode,
  /// to the log file. The file write is what makes a release-mode failure
  /// diagnosable after the fact.
  static void error(String message, [Object? err]) {
    final line = '[BoltMesh][ERR] $message${err == null ? '' : ': $err'}';
    if (kDebugMode) debugPrint(line);
    writeLogLine(line);
  }

  /// Truncates ids/keys (`abc123…`) so logs never carry full secrets.
  /// Returns `<null>` / `<empty>` markers to distinguish missing values, and
  /// `<redacted>` for values short enough that a truncation would echo the
  /// whole secret.
  static String redact(String? value) {
    if (value == null) return '<null>';
    if (value.isEmpty) return '<empty>';
    if (value.length <= 8) return '<redacted>';
    return '${value.substring(0, 8)}…';
  }
}
