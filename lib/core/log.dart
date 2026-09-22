import 'package:flutter/foundation.dart';

/// Minimal dev-console logger for the VPN connect flow.
///
/// Console only, no new dependencies. All output is gated by [kDebugMode]
/// so release builds stay silent. Never pass secrets here — use the
/// redaction helpers for ids/keys.
class AppLog {
  const AppLog._();

  static void info(String message) {
    if (kDebugMode) debugPrint('[BoltMesh] $message');
  }

  static void error(String message, [Object? err]) {
    if (kDebugMode) {
      debugPrint('[BoltMesh][ERR] $message${err == null ? '' : ': $err'}');
    }
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
