/// Platform identity: the backend `platform` enum label and the Apple
/// Network-Extension bundle ID.
///
/// Kept out of `wg_conf.dart` (a pure config builder) and out of the VPN
/// provider file so the platform/`--dart-define` concerns have one home.
library;

import 'package:flutter/foundation.dart';

/// Backend `platform` enum (backend/app/vpn/enums.py VpnDevicePlatformEnum).
String currentPlatformLabel() {
  // Explicit override wins (e.g. physical device tested over LAN, or web).
  const override = String.fromEnvironment('VPN_PLATFORM');
  if (override.isNotEmpty) return override;
  if (kIsWeb) return 'other';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'other';
  }
}

/// Network-extension bundle ID for iOS/macOS
/// (`--dart-define=VPN_PROVIDER_BUNDLE_ID=<ext id>`); ignored elsewhere.
const _kProviderBundleId = String.fromEnvironment('VPN_PROVIDER_BUNDLE_ID');

/// Resolves the bundle ID to hand to the tunnel plugin. The plugin
/// documents `providerBundleIdentifier` as iOS/macOS-only, so every other
/// platform (plus web) passes `''`. On Apple platforms a missing define
/// fails fast here instead of deep inside the native extension, where the
/// error is obscure. Parameters are injectable for tests.
String resolveProviderBundleId({
  TargetPlatform? platform,
  String bundleId = _kProviderBundleId,
  bool web = kIsWeb,
}) {
  if (web) return '';
  final p = platform ?? defaultTargetPlatform;
  if (p == TargetPlatform.iOS || p == TargetPlatform.macOS) {
    if (bundleId.isEmpty) {
      throw StateError(
        'Missing VPN_PROVIDER_BUNDLE_ID. Re-run with '
        '--dart-define=VPN_PROVIDER_BUNDLE_ID=<extension bundle id>.',
      );
    }
    return bundleId;
  }
  return '';
}
