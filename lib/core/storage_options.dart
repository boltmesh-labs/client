import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'storage_factory_stub.dart'
    if (dart.library.io) 'storage_factory_io.dart'
    as storage_factory;

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
/// - Linux uses a user-readable-only file through [kPlatformSecureStorage],
///   avoiding a desktop keyring. The file is not encrypted. Windows/Web keep
///   plugin defaults.
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

FlutterSecureStorage get kPlatformSecureStorage =>
    storage_factory.platformSecureStorage(kSharedSecureStorage);
