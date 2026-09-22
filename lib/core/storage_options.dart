import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hardened backing store for all BoltMesh secrets (auth tokens + device
/// identity + WireGuard keys).
///
/// The plugin defaults are weaker than they look:
/// - iOS/macOS default to `KeychainAccessibility.unlocked` (migrates to a
///   new device via backup) — here secrets are `first_unlock_this_device`
///   and non-syncable, so they never leave the device.
/// - Android defaults to `resetOnError: true`, which would silently wipe
///   the device identity on a KeyStore error — here errors surface so the
///   controller can report them instead of losing the WG keypair quietly.
/// - Linux/Windows/Web keep plugin defaults.
const kStorageIOS = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

const kStorageMacOS = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

const kStorageAndroid = AndroidOptions(resetOnError: false);

const kSharedSecureStorage = FlutterSecureStorage(
  iOptions: kStorageIOS,
  aOptions: kStorageAndroid,
  mOptions: kStorageMacOS,
);
