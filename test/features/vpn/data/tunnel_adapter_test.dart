import 'dart:async';

import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

/// Raw plugin fake with a scripted `stopVpn`: each `true` entry hangs past
/// [TunnelTuning.stopTimeout] (wedged driver), each `false`
/// entry stops cleanly.
class HangingTunnel implements WireGuardFlutterInterface {
  HangingTunnel(this.script);
  final List<bool> script;
  int stops = 0;

  @override
  Stream<VpnStage> get vpnStageSnapshot => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get trafficSnapshot => const Stream.empty();
  @override
  Future<void> initialize({
    required String interfaceName,
    String? vpnName,
    String? iosAppGroup,
    String? extensionBundleId,
  }) async {}
  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {}
  @override
  Future<void> stopVpn() async {
    stops++;
    if (script.isNotEmpty && script.removeAt(0)) {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  @override
  Future<Map<String, dynamic>> trafficStats() async => const {};
  @override
  Future<void> requestMacSystemExtension(String bundleId) async {}
  @override
  Future<bool> isConnected() async => false;
  @override
  Future<void> refreshStage() async {}
  @override
  Future<VpnStage> stage() async => VpnStage.connected;
  @override
  Future<bool> checkVpnPermission() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The global `test/flutter_test_config.dart` stubs the host channels with
  // "absent" answers so unrelated suites stay quiet. Clear them here so the
  // missing-handler contract below keeps exercising the real
  // `MissingPluginException` path instead of a stub returning null.
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      WireGuardTunnelAdapter.handshakeChannel,
      null,
    );
    messenger.setMockMethodCallHandler(
      WireGuardTunnelAdapter.ghostChannel,
      null,
    );
  });

  test('wedged stop retries the hard-kill and returns', () {
    // Field case: graceful teardown hangs (3s timeout), the automated
    // retry lands — `stop` never throws and the tunnel is down.
    fakeAsync((async) {
      final raw = HangingTunnel([true, false]);
      final adapter = WireGuardTunnelAdapter.test(raw);

      var done = false;
      unawaited(adapter.stop('config-refresh').then((_) => done = true));
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      expect(done, isTrue);
      expect(raw.stops, 2);
    });
  });

  test('double-wedged stop gives up quietly instead of throwing', () {
    fakeAsync((async) {
      final raw = HangingTunnel([true, true]);
      final adapter = WireGuardTunnelAdapter.test(raw);

      var done = false;
      unawaited(adapter.stop('auto-heal').then((_) => done = true));
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();

      expect(done, isTrue);
      expect(raw.stops, 2);
    });
  });

  test('injected handshake reader wins over the host channel', () async {
    final at = DateTime.utc(2026, 9, 19, 12);
    final adapter = WireGuardTunnelAdapter.test(
      HangingTunnel([]),
      handshakeReader: () async => at,
    );

    expect(await adapter.readHandshake(), at);
  });

  test('throwing handshake reader resolves as unknown, never throws', () async {
    final adapter = WireGuardTunnelAdapter.test(
      HangingTunnel([]),
      handshakeReader: () => throw StateError('wedged'),
    );

    expect(await adapter.readHandshake(), isNull);
  });

  test('missing host handler resolves as unknown, never throws', () async {
    // No native `com.boltmesh/handshake` handler under `flutter test`
    // (and no injected reader): MissingPluginException must not escape.
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

    expect(await adapter.readHandshake(), isNull);
  });

  test(
    'missing ghost channel resolves peer as unknown, never throws',
    () async {
      // No native `com.boltmesh/tunnel` handler under `flutter test`:
      // MissingPluginException must not escape.
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      expect(await adapter.getActivePeer(), isNull);
    },
  );

  test('missing ghost channel makes killGhost a no-op false', () async {
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

    expect(await adapter.killGhost(), isFalse);
    expect(adapter.ghostKills, 1);
  });

  // The contract the native hosts must satisfy: Android's `TunnelHost` answers
  // these channels with the shapes exercised here. Windows no longer uses
  // them (its helper owns the reads).
  group('host channel contract', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.handshakeChannel,
        null,
      );
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.ghostChannel,
        null,
      );
    });

    test('parses epoch seconds from the handshake channel', () async {
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.handshakeChannel,
        (call) async {
          expect(call.method, 'getLastHandshake');
          return 1718000000.0;
        },
      );
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      expect(
        await adapter.readHandshake(),
        DateTime.fromMillisecondsSinceEpoch(1718000000 * 1000, isUtc: true),
      );
    });

    test('null and zero handshakes resolve as unknown', () async {
      final values = <Object?>[null, 0.0];
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.handshakeChannel,
        (call) async => values.removeAt(0),
      );
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      expect(await adapter.readHandshake(), isNull);
      expect(await adapter.readHandshake(), isNull);
    });

    test('parses the active peer map', () async {
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.ghostChannel,
        (call) async => call.method == 'getActivePeer'
            ? {'publicKey': 'SRVKEY', 'endpoint': '[2001:db8::1]:51820'}
            : null,
      );
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      final peer = await adapter.getActivePeer();
      expect(peer?.publicKey, 'SRVKEY');
      expect(peer?.endpoint, '[2001:db8::1]:51820');
    });

    test('a blank public key resolves as unknown', () async {
      messenger.setMockMethodCallHandler(
        WireGuardTunnelAdapter.ghostChannel,
        (call) async => {'publicKey': '  ', 'endpoint': '203.0.113.10:51820'},
      );
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      expect(await adapter.getActivePeer(), isNull);
    });

    test('killGhost returns the host result', () async {
      messenger.setMockMethodCallHandler(WireGuardTunnelAdapter.ghostChannel, (
        call,
      ) async {
        expect(call.method, 'killGhost');
        return true;
      });
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

      expect(await adapter.killGhost(), isTrue);
      expect(adapter.ghostKills, 1);
    });
  });

  group('handshakeReaderSupported', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('true on Android only, false elsewhere (helper/Apple)', () {
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));
      const expectations = {
        TargetPlatform.android: true,
        TargetPlatform.windows: false,
        TargetPlatform.iOS: false,
        TargetPlatform.macOS: false,
        TargetPlatform.linux: false,
      };
      expectations.forEach((platform, expected) {
        debugDefaultTargetPlatformOverride = platform;
        expect(adapter.handshakeReaderSupported, expected, reason: '$platform');
      });
    });

    test('an injected reader is always supported', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final adapter = WireGuardTunnelAdapter.test(
        HangingTunnel([]),
        handshakeReader: () async => null,
      );

      expect(adapter.handshakeReaderSupported, isTrue);
    });
  });
}
