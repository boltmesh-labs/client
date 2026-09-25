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

/// App Group shared container for iOS/macOS
/// (`--dart-define=VPN_APP_GROUP=group.<...>`); ignored elsewhere.
const _kAppGroup = String.fromEnvironment('VPN_APP_GROUP');

/// Resolves the App Group ID to hand to the tunnel plugin.
///
/// The app and its Packet Tunnel extension must share one App Group: the
/// extension reads the `wgQuick` config the app hands over through that
/// container. `wireguard_flutter_plus` falls back to
/// `group.orbanvpn.wireguard` when this is null, which is in nobody's
/// provisioning profile — the connection then fails deep inside the
/// extension with an opaque error. Failing fast here names the missing
/// define instead. Parameters are injectable for tests.
String resolveAppGroup({
  TargetPlatform? platform,
  String appGroup = _kAppGroup,
  bool web = kIsWeb,
}) {
  if (web) return '';
  final p = platform ?? defaultTargetPlatform;
  if (p == TargetPlatform.iOS || p == TargetPlatform.macOS) {
    if (appGroup.isEmpty) {
      throw StateError(
        'Missing VPN_APP_GROUP. Re-run with '
        '--dart-define=VPN_APP_GROUP=group.<app group id> (the App Group '
        'shared by the app and its Network Extension).',
      );
    }
    return appGroup;
  }
  return '';
}

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
