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

/// True where the obfuscated (AmneziaWG) data plane is available: the Linux
/// `boltmeshd` helper runs the device in-process. The Windows helper's
/// data plane has no obfuscated path (yet), Android's plugin cannot be
/// forking (see `tunnel_adapter.dart`), and Apple is the Network Extension.
///
/// An obfuscated region's node runs the AmneziaWG device, so a stock datagram
/// is illegible to it: off Linux the region is unservable, and the ladder has
/// no floor to raise to (see `conn_obfuscation.dart`). The data-plane work is
/// what closes that gap; this predicate is the single place it is decided.
/// Parameters injectable for tests.
bool awgDataPlaneSupported({TargetPlatform? platform, bool web = kIsWeb}) {
  if (web) return false;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.linux;
}

/// True where the stream transport is available: the Linux `boltmeshd` helper
/// runs the bridge in-process, and it is the only build whose transport
/// lifecycle and bypass route exist. Everywhere else the daemon *rejects* a
/// transport spec rather than ignoring it, so a rung selected there could only
/// fail — the platform gate keeps the ladder from offering it.
///
/// This is the static half of the gate; the runtime half is the daemon's
/// advertised `stream-transport` capability, which also covers a Linux helper
/// that is too old to know the transport at all.
bool streamTransportSupported({TargetPlatform? platform, bool web = kIsWeb}) {
  if (web) return false;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.linux;
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
