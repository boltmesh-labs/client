// Global test bootstrap. `flutter_test_config.dart` is discovered by walking up
// from each test file, so this one copy runs before every suite under `test/`.
//
// Plain `test()` suites never call `runApp()`, so `ServicesBinding.instance`
// stays unset unless a widget test happens to run first. Production providers
// nonetheless reach for platform state while building — secure-storage reads in
// the auth/device stores — and those logged "Binding has not yet been
// initialized". Initializing the binding is only half the fix: with a binding
// but no host plugin the same calls fail as `MissingPluginException`. The stub
// below answers that channel with the "no value" reply the store already reads
// as absent, so the plain suites stay quiet without changing their behaviour.
//
// Store *logic* stays covered by `session_store_test` / `device_store_test`,
// which inject `MapSecureStorage` below the channel. No tunnel host channel is
// stubbed any more: the plugin adapter reaches no channel at all (its reads are
// unknown by construction) and the Android adapter's channel is covered by
// `tunnel_adapter_test`, which stubs it per test.

import 'dart:async';

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
  await testMain();
}
