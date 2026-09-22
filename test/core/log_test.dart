import 'package:boltmesh/core/log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redact never returns the full value', () {
    const secret = 'supersecrettokenvalue123';
    final redacted = AppLog.redact(secret);
    expect(redacted, isNot(secret));
    expect(secret.startsWith(redacted.substring(0, 8)), isTrue);
    expect(redacted, endsWith('…'));
  });

  test('redact marks missing values', () {
    expect(AppLog.redact(null), '<null>');
    expect(AppLog.redact(''), '<empty>');
  });

  test('redact never echoes a short value', () {
    expect(AppLog.redact('abc'), '<redacted>');
    expect(AppLog.redact('12345678'), '<redacted>');
  });
}
