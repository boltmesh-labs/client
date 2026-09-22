import 'package:boltmesh/core/locale.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const supported = [Locale('en'), Locale('de')];

  test('matched device locale wins, including region variants', () {
    expect(resolveAppLocale(const Locale('de'), supported), const Locale('de'));
    expect(
      resolveAppLocale(const Locale('de', 'AT'), supported),
      const Locale('de'),
    );
  });

  test('unknown and missing locales fall back to English', () {
    expect(resolveAppLocale(const Locale('fr'), supported), const Locale('en'));
    expect(resolveAppLocale(null, supported), const Locale('en'));
  });
}
