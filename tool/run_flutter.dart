// Runs `flutter` with every variable in `.env` forwarded as a `--dart-define`.
//
// The API URL is a compile-time `String.fromEnvironment` (see
// `lib/core/env.dart`), so the value has to reach the compiler, not the
// running app. This reads it from a single gitignored file instead of a
// default baked into `lib/` — a fresh clone falls back to the local
// `podman-compose` stack, and anyone who needs the real backend copies
// `.env.example` to `.env` once.
//
// Usage (from `client/`):
//
//   cp .env.example .env          # once; optional
//   dart run tool/run_flutter.dart run
//   dart run tool/run_flutter.dart build apk --debug
//   dart run tool/run_flutter.dart build linux --release
//
// Every argument after the script is forwarded to `flutter` untouched, so
// this is a drop-in for any `flutter` invocation. Plain `flutter run` and the
// IDE's run buttons still work — they just add no defines and therefore get
// `Env`'s localhost default, which is what a debug build wants anyway.
//
// Release packaging is unaffected: `distribute_options.yaml` pins the
// production URL per job, so CI never needs a `.env` of its own.
import 'dart:io';

/// Skippable line shapes: a whole-line comment, a blank line, and the key
/// grammar a valid assignment must match.
final _comment = RegExp(r'^\s*#');
final _blank = RegExp(r'^\s*$');
final _key = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Parses dotenv-style `KEY=VALUE` lines from [contents].
///
/// Tolerates `#` comments, blank lines, CRLF, an `export ` prefix, and one
/// layer of matching single or double quotes. Splits on the *first* `=` so
/// values may contain more. A later assignment wins.
///
/// Malformed lines are skipped rather than fatal: a typo in `.env` should not
/// read as "the app is misconfigured", it should read as "that one line did
/// not apply". Skipped lines are reported through [onWarning] with their
/// 1-based line number.
Map<String, String> parseEnvFile(
  String contents, {
  void Function(String)? onWarning,
}) {
  final result = <String, String>{};
  final lines = contents.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_blank.hasMatch(line) || _comment.hasMatch(line)) continue;

    final withoutExport = line.trimLeft().startsWith('export ')
        ? line.trimLeft().substring('export '.length)
        : line;
    final separator = withoutExport.indexOf('=');
    if (separator <= 0) {
      onWarning?.call('.env:${i + 1}: not a KEY=VALUE assignment, skipped');
      continue;
    }

    final key = withoutExport.substring(0, separator).trim();
    if (!_key.hasMatch(key)) {
      onWarning?.call('.env:${i + 1}: "$key" is not a valid key, skipped');
      continue;
    }

    result[key] = _unquote(withoutExport.substring(separator + 1).trim());
  }
  return result;
}

/// Strips one layer of matching single or double quotes.
///
/// Quotes are only removed when they wrap the *whole* value, so a value that
/// merely starts with a quote (`"a" and b`) keeps it rather than becoming
/// `a" and b`.
String _unquote(String value) {
  if (value.length < 2) return value;
  final first = value[0];
  if ((first != '"' && first != "'") || !value.endsWith(first)) return value;
  return value.substring(1, value.length - 1);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/run_flutter.dart <flutter args...>\n'
      '  e.g. dart run tool/run_flutter.dart run',
    );
    exit(2);
  }

  final envFile = File('.env');
  final defines = <String>[];
  if (envFile.existsSync()) {
    final values = parseEnvFile(
      envFile.readAsStringSync(),
      onWarning: stderr.writeln,
    );
    defines.addAll(
      values.entries.map((e) => '--dart-define=${e.key}=${e.value}'),
    );
    // Keys only, never values: `.env` is gitignored precisely because it may
    // hold something sensitive one day, and build logs are copied around.
    stderr.writeln(
      values.isEmpty
          ? 'No defines in .env; using built-in defaults.'
          : 'Applying .env defines: ${values.keys.join(', ')}',
    );
  } else {
    stderr.writeln(
      'No .env found; using built-in defaults. Copy .env.example to .env to '
      'point the build at another API.',
    );
  }

  // `flutter` resolves through runInShell on Windows, where it is a .bat that
  // CreateProcess cannot launch directly. FLUTTER overrides the binary for
  // setups where the SDK is not on PATH.
  final flutter = Platform.environment['FLUTTER'] ?? 'flutter';
  final Process process;
  try {
    process = await Process.start(
      flutter,
      [...args, ...defines],
      // The child owns the terminal, so Ctrl-C reaches flutter and its own
      // children instead of orphaning a half-shut-down run.
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (e) {
    stderr.writeln(
      "Could not start '$flutter' (${e.message}). Install the Flutter SDK and "
      'put it on PATH, or set FLUTTER to its absolute path.',
    );
    exit(127);
  }

  // Propagate the child's status so wrappers, CI, and `&&` chains see the
  // real result of the build.
  exit(await process.exitCode);
}
