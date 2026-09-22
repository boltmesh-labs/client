import 'package:boltmesh/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG relative-luminance contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('connected colors clear WCAG AA in both brightnesses', () {
    for (final theme in [boltMeshTheme, boltMeshDarkTheme]) {
      final colors = theme.extension<BoltMeshColors>();
      expect(colors, isNotNull);
      expect(
        _contrast(colors!.onConnected, colors.connected),
        greaterThanOrEqualTo(4.5),
        reason: 'connected foreground must be readable on ${colors.connected}',
      );
    }
  });
}
