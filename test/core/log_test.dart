import 'dart:io';

import 'package:boltmesh/core/log.dart';
import 'package:boltmesh/core/log_file.dart';
import 'package:boltmesh/core/log_file_io.dart'
    show kMaxLogBackups, kMaxLogBytes;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('boltmesh_log_test');
    setLogDirectory(tempDir.path);
  });

  tearDown(() {
    setLogDirectory(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String logPath() => '${tempDir.path}${Platform.pathSeparator}boltmesh.log';

  group('redact', () {
    test('never returns the full value', () {
      const secret = 'supersecrettokenvalue123';
      final redacted = AppLog.redact(secret);
      expect(redacted, isNot(secret));
      expect(secret.startsWith(redacted.substring(0, 8)), isTrue);
      expect(redacted, endsWith('…'));
    });

    test('marks missing values', () {
      expect(AppLog.redact(null), '<null>');
      expect(AppLog.redact(''), '<empty>');
    });

    test('never echoes a short value', () {
      expect(AppLog.redact('abc'), '<redacted>');
      expect(AppLog.redact('12345678'), '<redacted>');
    });
  });

  group('file sink', () {
    test('persists an error line with its detail', () {
      AppLog.error(
        'auth POST /auth/login',
        'SocketException: failed host lookup',
      );

      final written = File(logPath()).readAsStringSync();
      expect(written, contains('auth POST /auth/login'));
      expect(written, contains('SocketException: failed host lookup'));
      expect(written, endsWith('\n'));
    });

    test('appends rather than truncating', () {
      AppLog.error('first');
      AppLog.error('second');

      final lines = File(logPath()).readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines.first, contains('first'));
      expect(lines.last, contains('second'));
    });

    test('info stays out of the file', () {
      AppLog.info('poll tick');

      expect(File(logPath()).existsSync(), isFalse);
    });

    test('creates the directory on first write', () {
      final nested = Directory(
        '${tempDir.path}${Platform.pathSeparator}not${Platform.pathSeparator}'
        'yet${Platform.pathSeparator}deep',
      );
      setLogDirectory(nested.path);

      AppLog.error('into a missing directory');

      expect(
        File('${nested.path}${Platform.pathSeparator}boltmesh.log')
            .existsSync(),
        isTrue,
      );
    });

    test('a failing target does not throw', () {
      // A path whose parent is a regular file cannot be created or opened.
      final blocker = File('${tempDir.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('not a directory');
      setLogDirectory('${blocker.path}${Platform.pathSeparator}under');

      expect(() => AppLog.error('must not escape'), returnsNormally);
    });

    test('reports the configured directory', () {
      expect(logDirectory, tempDir.path);
    });
  });

  group('rotation', () {
    test('moves the active file to .1 and starts fresh', () {
      final path = logPath();
      // One byte under the cap, so the next write rotates.
      File(path).writeAsStringSync('x' * (1024 * 1024 - 8));

      AppLog.error('this line tips it over');

      expect(File('$path.1').existsSync(), isTrue);
      final rotated = File('$path.1').readAsStringSync();
      expect(rotated.length, 1024 * 1024 - 8);
      expect(File(path).readAsStringSync(), contains('this line tips it over'));
    });

    test('drops the oldest backup past the cap', () {
      final path = logPath();
      // Rotation needs a non-empty active file that the next write would push
      // past the cap, so seed one at the size that trips it.
      File(path).writeAsStringSync('a' * (kMaxLogBytes - 8));
      for (var i = 1; i <= kMaxLogBackups; i++) {
        File('$path.$i').writeAsStringSync('backup $i');
      }

      AppLog.error('rotate now');

      expect(File('$path.1').lengthSync(), kMaxLogBytes - 8);
      expect(
        File('$path.$kMaxLogBackups').readAsStringSync(),
        'backup ${kMaxLogBackups - 1}',
      );
      expect(File('$path.${kMaxLogBackups + 1}').existsSync(), isFalse);
    });

    test('leaves backups alone when the active file is empty', () {
      final path = logPath();
      File(path).writeAsStringSync('');
      File('$path.1').writeAsStringSync('backup 1');

      AppLog.error('small first line');

      expect(File('$path.1').readAsStringSync(), 'backup 1');
      expect(File(path).readAsStringSync(), contains('small first line'));
    });

    test('a single line larger than the cap still lands', () {
      final path = logPath();
      File(path).writeAsStringSync('x' * (1024 * 1024 + 1));

      AppLog.error('oversized predecessor');

      expect(File('$path.1').readAsStringSync(), isNotEmpty);
      expect(File(path).readAsStringSync(), contains('oversized predecessor'));
    });
  });

  group('test-run isolation', () {
    test('the sink resolves a directory only when opted in', () {
      setLogDirectory(null);
      // Under `flutter test` FLUTTER_TEST is set, so default resolution must
      // yield null rather than the developer's real log directory.
      expect(isUnderTest, isTrue);
      expect(logDirectory, isNull);
    });
  });
}
