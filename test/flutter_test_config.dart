// Global test bootstrap. `flutter_test_config.dart` is discovered by walking up
// from each test file, so this one copy runs before every suite under `test/`.
//
// Plain `test()` suites never call `runApp()`, so `ServicesBinding.instance`
// stays unset unless a widget test happens to run first. Production providers
// nonetheless reach for platform state while building — secure-storage reads in
// the auth/device stores and the `com.boltmesh/{handshake,tunnel}` host channels
// in the tunnel adapter — and every one of them logged "Binding has not yet
// been initialized". Initializing the binding is only half the fix: with a
// binding but no host plugin the same calls fail as `MissingPluginException`,
// which their handlers report as real errors. The stubs below answer those
// channels with the "absent" values the production catch branches already treat
// as unknown, so the plain suites stay quiet without changing their behaviour.
//
// Store *logic* stays covered by `session_store_test` / `device_store_test`,
// which inject `MapSecureStorage` below the channel, and the host-channel
// contract stays covered by `tunnel_adapter_test`, which clears these stubs
// before exercising the real missing-handler path.

import 'dart:async';

import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `flutter_secure_storage` plugin channel (not exposed as a public
/// constant). Reads answer "no value", writes are accepted.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    _secureStorageChannel,
    (call) async => null,
  );
  // No native host under `flutter test`: handshakes/peers read as unknown and
  // the ghost-kill is a no-op, exactly as their catch branches already decide.
  messenger.setMockMethodCallHandler(
    WireGuardTunnelAdapter.handshakeChannel,
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    WireGuardTunnelAdapter.ghostChannel,
    (call) async => call.method == 'killGhost' ? false : null,
  );
  await testMain();
}
