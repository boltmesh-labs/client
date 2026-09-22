import 'package:flutter/material.dart';

/// Semantic tunnel-state colors Material's [ColorScheme] has no slot for
/// (there is no "connected"/"success" role). Each pair is chosen to clear
/// WCAG AA (4.5:1) for [onConnected] on [connected] in its brightness.
@immutable
class BoltMeshColors extends ThemeExtension<BoltMeshColors> {
  const BoltMeshColors({required this.connected, required this.onConnected});

  /// Tunnel-up accent (status icon, hero power button background).
  final Color connected;

  /// Foreground drawn on [connected].
  final Color onConnected;

  @override
  BoltMeshColors copyWith({Color? connected, Color? onConnected}) =>
      BoltMeshColors(
        connected: connected ?? this.connected,
        onConnected: onConnected ?? this.onConnected,
      );

  @override
  BoltMeshColors lerp(ThemeExtension<BoltMeshColors>? other, double t) {
    if (other is! BoltMeshColors) return this;
    return BoltMeshColors(
      connected: Color.lerp(connected, other.connected, t)!,
      onConnected: Color.lerp(onConnected, other.onConnected, t)!,
    );
  }
}

const _lightColors = BoltMeshColors(
  // Green 800: ~5.1:1 against white.
  connected: Color(0xFF2E7D32),
  onConnected: Colors.white,
);

const _darkColors = BoltMeshColors(
  // Green 500: ~7.6:1 against black.
  connected: Color(0xFF4CAF50),
  onConnected: Colors.black,
);

/// [BoltMeshColors] for the active theme. Falls back to the light values for
/// a bare [ThemeData] (e.g. a widget test that does not use [boltMeshTheme]).
BoltMeshColors boltMeshColorsOf(BuildContext context) =>
    Theme.of(context).extension<BoltMeshColors>() ?? _lightColors;

/// App-wide Material 3 themes.
///
/// One home so the widget previews render exactly what production does
/// (they previously re-declared an identical pair of `ThemeData`s).
final ThemeData boltMeshTheme = ThemeData(
  colorSchemeSeed: Colors.teal,
  useMaterial3: true,
  extensions: const [_lightColors],
);

final ThemeData boltMeshDarkTheme = ThemeData(
  colorSchemeSeed: Colors.teal,
  brightness: Brightness.dark,
  useMaterial3: true,
  extensions: const [_darkColors],
);
