// Tests for the `.env` parser behind `tool/run_flutter.dart`.
//
// The parser is pure and lives in `tool/` rather than `lib/`, so this is the
// one place `test/` does not mirror `lib/`. It is worth covering: a silently
// dropped line here becomes an app pointing at the wrong API.
import 'package:flutter_test/flutter_test.dart';

import '../../tool/run_flutter.dart';

void main() {
  group('parseEnvFile', () {
    test('reads plain assignments', () {
      final env = parseEnvFile('API_BASE_URL=https://api.example.com/v1');
      expect(env, {'API_BASE_URL': 'https://api.example.com/v1'});
    });

    test('ignores blank lines and whole-line comments', () {
      final env = parseEnvFile('''

        # a comment
        \t
          # an indented comment
        API_BASE_URL=https://api.example.com/v1
      ''');
      expect(env, {'API_BASE_URL': 'https://api.example.com/v1'});
    });

    test('keeps a # that is inside a value', () {
      final env = parseEnvFile('API_BASE_URL=https://api.example.com/v1#frag');
      expect(env['API_BASE_URL'], 'https://api.example.com/v1#frag');
    });

    test('trims whitespace around the key and value', () {
      final env = parseEnvFile(
        '  API_BASE_URL  =  https://api.example.com/v1  ',
      );
      expect(env, {'API_BASE_URL': 'https://api.example.com/v1'});
    });

    test('accepts an export prefix', () {
      final env = parseEnvFile(
        'export API_BASE_URL=https://api.example.com/v1',
      );
      expect(env, {'API_BASE_URL': 'https://api.example.com/v1'});
    });

    test('strips one layer of matching quotes', () {
      final values = parseEnvFile('''
API_BASE_URL="https://api.example.com/v1"
TLS_PIN_SPKI_SHA256='pin=='
''');
      expect(values['API_BASE_URL'], 'https://api.example.com/v1');
      expect(values['TLS_PIN_SPKI_SHA256'], 'pin==');
    });

    test('keeps quotes that do not wrap the whole value', () {
      // Quotes wrap only part of the value: left alone.
      expect(
        parseEnvFile('API_BASE_URL="a" and b')['API_BASE_URL'],
        '"a" and b',
      );
      // Unbalanced: a leading quote with no closing partner is not stripped.
      expect(parseEnvFile(r'API_BASE_URL="a')['API_BASE_URL'], '"a');
      // Mismatched pair: not half-stripped either.
      expect(
        parseEnvFile(
          """API_BASE_URL='https://api.example.com/v1\"""",
        )['API_BASE_URL'],
        "'https://api.example.com/v1\"",
      );
    });

    test('splits on the first = so values may contain more', () {
      final env = parseEnvFile(
        'API_BASE_URL=https://api.example.com/v1?a=b&c=d',
      );
      expect(env['API_BASE_URL'], 'https://api.example.com/v1?a=b&c=d');
    });

    test('accepts CRLF line endings', () {
      final env = parseEnvFile(
        '# comment\r\nAPI_BASE_URL=https://api.example.com/v1\r\nVPN_PLATFORM=android\r\n',
      );
      expect(env, {
        'API_BASE_URL': 'https://api.example.com/v1',
        'VPN_PLATFORM': 'android',
      });
    });

    test('lets a later assignment win', () {
      final env = parseEnvFile('''
API_BASE_URL=https://first.example/v1
API_BASE_URL=https://second.example/v1
''');
      expect(env['API_BASE_URL'], 'https://second.example/v1');
    });

    test('keeps an empty value, which is how a define is unset', () {
      final env = parseEnvFile('API_BASE_URL=\nVPN_PLATFORM=\n');
      expect(env, {'API_BASE_URL': '', 'VPN_PLATFORM': ''});
    });

    test('skips a line with no assignment, naming the line number', () {
      final warnings = <String>[];
      final env = parseEnvFile(
        'API_BASE_URL=https://api.example.com/v1\nnonsense\n',
        onWarning: warnings.add,
      );
      expect(env, {'API_BASE_URL': 'https://api.example.com/v1'});
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('.env:2'));
    });

    test('skips an invalid key and a leading =', () {
      final warnings = <String>[];
      final env = parseEnvFile(
        '9INVALID=x\n=novalue\nVPN PLATFORM=android\n',
        onWarning: warnings.add,
      );
      expect(env, isEmpty);
      expect(warnings, hasLength(3));
      expect(warnings[0], contains('.env:1'));
      expect(warnings[1], contains('.env:2'));
      expect(warnings[2], contains('.env:3'));
    });

    test('is empty for an absent or comment-only file', () {
      expect(parseEnvFile(''), isEmpty);
      expect(parseEnvFile('# nothing here\n\n'), isEmpty);
    });
  });
}
