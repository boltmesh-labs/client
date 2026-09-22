import 'package:flutter/widgets.dart';

/// Device-locale → supported-locale resolution for `MaterialApp`.
///
/// English is the default fallback: unmatched device locales (e.g. `fr`)
/// resolve to `en` instead of the first supported locale. Pure so the
/// fallback is unit-testable without pumping a widget.
Locale resolveAppLocale(Locale? locale, Iterable<Locale> supported) {
  if (locale == null) return const Locale('en');
  for (final s in supported) {
    if (s.languageCode == locale.languageCode) return s;
  }
  return const Locale('en');
}
