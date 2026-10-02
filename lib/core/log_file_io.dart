/// Durable, size-bounded file sink for [AppLog].
///
/// The console logger is gated on `kDebugMode`, which is right for a shipped
/// desktop app but leaves release builds with nowhere to record a failure:
/// a GUI app's stdout is discarded when it is launched from Explorer or a
/// service session, so the diagnostic line that `dio_client` writes on a
/// transport failure (`underlying=<SocketException>`) simply does not exist
/// in the build users run. `boltmeshd` solves the same problem with a rotating
/// file under ProgramData; this is the client-side equivalent, in the user's
/// own application-support directory so it needs no elevation.
///
/// Only [AppLog.error] is persisted. Info-level lines stay debug-only, so a
/// release log holds failures rather than a transcript of every poll.
library;

import 'dart:io';

/// Bounds the persistent log. Five files of at most 1 MiB each cap the
/// on-disk footprint at ~5 MiB, which is small enough to survive on a busy
/// machine and large enough to hold a failure report.
const kMaxLogBytes = 1 << 20;
const kMaxLogBackups = 5;

/// Flutter's test runner sets `FLUTTER_TEST`. The suites must never write into
/// the developer's real log directory, so the sink stays off unless a test
/// opts in with [setLogDirectory].
bool get isUnderTest => Platform.environment.containsKey('FLUTTER_TEST');

String? _overrideDirectory;

/// Resolved once: creating the directory and probing writability must not run
/// on every log line.
String? _resolvedDirectory;
bool _resolved = false;

/// The directory the sink writes into, or null when file logging is off.
String? get logDirectory {
  if (_overrideDirectory != null) return _overrideDirectory;
  if (_resolved) return _resolvedDirectory;
  _resolved = true;
  if (isUnderTest) return _resolvedDirectory = null;
  _resolvedDirectory = _resolveDirectory();
  return _resolvedDirectory;
}

/// Points the sink at [directory] instead of the platform default. Passing null
/// restores default resolution. For tests.
void setLogDirectory(String? directory) {
  _overrideDirectory = directory;
  _resolved = false;
  _resolvedDirectory = null;
}

/// The per-user application-support directory for this app's log.
///
/// Windows uses LOCALAPPDATA (per-user, not synced, not world-readable);
/// macOS uses Library/Logs per the platform convention; everything else falls
/// back to XDG_STATE_HOME, then `$HOME/.local/state`. Returns null when no
/// usable location exists rather than guessing at a world-writable path.
String? _resolveDirectory() {
  final env = Platform.environment;
  String? base;
  if (Platform.isWindows) {
    base = env['LOCALAPPDATA'];
  } else if (Platform.isMacOS) {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      base =
          '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Logs';
    }
  } else {
    base = env['XDG_STATE_HOME'];
    if (base == null || base.isEmpty) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        base =
            '$home${Platform.pathSeparator}.local${Platform.pathSeparator}state';
      }
    }
  }
  if (base == null || base.isEmpty) return null;
  return '$base${Platform.pathSeparator}boltmesh';
}

/// The active log file, `boltmesh.log` beside the directory above.
String _logPath(String directory) =>
    '$directory${Platform.pathSeparator}boltmesh.log';

/// Persists one line, appending a newline. Rotates first when the next record
/// would push the file past [kMaxLogBytes], so a record never straddles two
/// files.
///
/// Every failure is swallowed. This runs on the caller's error path, often
/// while handling another failure, and a broken log target (read-only volume,
/// revoked directory) must not escalate into an app-level crash.
void writeLogLine(String line) {
  final directory = logDirectory;
  if (directory == null) return;
  try {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = _logPath(directory);
    final file = File(path);
    final length = file.existsSync() ? file.lengthSync() : 0;
    if (length > 0 && length + line.length + 1 > kMaxLogBytes) {
      _rotate(path);
    }
    file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Nothing to do: an unwritable log target must not affect the app.
  } on Object {
    // Same reasoning for anything else the platform layer can throw.
  }
}

/// Shifts `path` to `path.1`, `path.1` to `path.2` and so on, dropping whatever
/// falls past [kMaxLogBackups]. Newest backup is `.1`.
void _rotate(String path) {
  final oldest = '$path.$kMaxLogBackups';
  if (File(oldest).existsSync()) File(oldest).deleteSync();
  for (var i = kMaxLogBackups - 1; i >= 1; i--) {
    final from = '$path.$i';
    if (File(from).existsSync()) {
      File(from).renameSync('$path.${i + 1}');
    }
  }
  final active = File(path);
  if (active.existsSync()) active.renameSync('$path.1');
}
