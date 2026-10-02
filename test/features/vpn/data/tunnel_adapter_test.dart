import 'dart:async';
import 'dart:convert';

import 'package:boltmesh/features/vpn/data/helper_client.dart'
    show capStreamTransport;
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/stream_transport.dart';
import 'package:boltmesh/features/vpn/data/tunnel_adapter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

/// Raw plugin fake with a scripted `stopVpn`: each `true` entry hangs past
/// [TunnelTuning.stopTimeout] (wedged driver), each `false`
/// entry stops cleanly.
class HangingTunnel implements WireGuardFlutterInterface {
  HangingTunnel(this.script);
  final List<bool> script;
  final List<String> configs = [];
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
  }) async {
    initialized = true;
    this.interfaceName = interfaceName;
    this.iosAppGroup = iosAppGroup;
  }

  /// Records what the adapter handed the plugin on `initialize`.
  bool initialized = false;
  String? interfaceName;

  /// Null here means the adapter omitted the App Group, which on Apple makes
  /// the plugin fall back to a group no provisioning profile contains.
  String? iosAppGroup;
  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    configs.add(wgQuickConfig);
  }

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

    group('requestConsent', () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('returns the host answer on Android', () async {
        for (final granted in [true, false]) {
          var calls = 0;
          messenger.setMockMethodCallHandler(
            WireGuardTunnelAdapter.ghostChannel,
            (call) async {
              expect(call.method, 'requestVpnConsent');
              calls++;
              return granted;
            },
          );
          final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

          expect(await adapter.requestConsent(), granted);
          expect(calls, 1, reason: 'consent must be asked exactly once');
        }
      });

      test('no-op off Android, without touching the host channel', () async {
        messenger.setMockMethodCallHandler(
          WireGuardTunnelAdapter.ghostChannel,
          (call) async => fail('must not ask for consent on ${call.method}'),
        );
        final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

        for (final platform in [
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          expect(await adapter.requestConsent(), isTrue, reason: '$platform');
        }
      });

      test('a missing host answers granted, deferring to start', () async {
        // The group's tearDown cleared the mock, so this is the real
        // MissingPluginException path. There is no dialog to show without a
        // native host, and `start` fails on its own terms if the platform is
        // genuinely wrong.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

        expect(await adapter.requestConsent(), isTrue);
      });

      test('a null host answer counts as granted', () async {
        // Android with no VpnService to consent to must not read as denied.
        messenger.setMockMethodCallHandler(
          WireGuardTunnelAdapter.ghostChannel,
          (call) async => null,
        );
        final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

        expect(await adapter.requestConsent(), isTrue);
      });

      test('a failing host answers denied rather than throwing', () async {
        // Fail closed: reporting "granted" would push the dialog back inside
        // `start`'s 10s budget, the exact failure this split exists to avoid.
        messenger.setMockMethodCallHandler(
          WireGuardTunnelAdapter.ghostChannel,
          (call) async => throw PlatformException(code: 'NO_ACTIVITY'),
        );
        final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

        expect(await adapter.requestConsent(), isFalse);
      });
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

  group('ensureInitialized', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('passes the App Group to the plugin on Apple', () async {
      // The Packet Tunnel extension reads the wgQuick config out of the
      // shared App Group container. Omitting it made the plugin fall back to
      // `group.orbanvpn.wireguard` — in no provisioning profile — so the
      // connect failed inside the extension with an opaque error.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final tunnel = HangingTunnel([]);
      final adapter = WireGuardTunnelAdapter.testUninitialized(tunnel);

      await expectLater(
        adapter.ensureInitialized(),
        throwsStateError,
        reason: 'a misconfigured Apple build must fail fast, naming the define',
      );
      expect(
        tunnel.initialized,
        isFalse,
        reason: 'the plugin must not be initialized without a valid App Group',
      );
      expect(adapter.isReady, isFalse);
    });

    test('passes an empty App Group off Apple', () async {
      // The plugin ignores it elsewhere; empty keeps the call site uniform and
      // avoids implying an App Group exists on a platform without one.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final tunnel = HangingTunnel([]);
      final adapter = WireGuardTunnelAdapter.testUninitialized(tunnel);

      await adapter.ensureInitialized();

      expect(tunnel.initialized, isTrue);
      expect(tunnel.iosAppGroup, '');
      expect(tunnel.interfaceName, 'boltmesh0');
      expect(adapter.isReady, isTrue);
    });
  });

  group('AndroidTunnelAdapter', () {
    const awgConfig = '[Interface]\nPrivateKey = test\nJc = 4\n';
    const stockConfig = '[Interface]\nPrivateKey = test\n';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, null);
    });

    test(
      'routes obfuscated configs to AWG after releasing stock TUN',
      () async {
        final tunnel = HangingTunnel([]);
        final adapter = AndroidTunnelAdapter(
          stock: WireGuardTunnelAdapter.test(tunnel),
        );
        final calls = <String>[];
        messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, (
          call,
        ) async {
          calls.add(call.method);
          return <String, Object?>{'up': call.method == 'startAwg'};
        });

        await adapter.start(
          serverAddress: '198.51.100.1',
          wgQuickConfig: awgConfig,
          providerBundleId: '',
        );

        expect(calls, ['stopAwg', 'startAwg']);
        expect(tunnel.stops, 1);
        expect(tunnel.configs, isEmpty);
      },
    );

    test('keeps stock configs on wireguard_flutter_plus', () async {
      final tunnel = HangingTunnel([]);
      final adapter = AndroidTunnelAdapter(
        stock: WireGuardTunnelAdapter.test(tunnel),
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, (
        call,
      ) async {
        calls.add(call.method);
        return <String, Object?>{'up': false};
      });

      await adapter.start(
        serverAddress: '198.51.100.1',
        wgQuickConfig: stockConfig,
        providerBundleId: '',
      );

      expect(calls, ['stopAwg']);
      expect(tunnel.configs, [stockConfig]);
    });

    test('advertises the stream capability of its native bridge', () {
      final adapter = AndroidTunnelAdapter(
        stock: WireGuardTunnelAdapter.test(HangingTunnel([])),
      );
      expect(adapter.daemonCapabilities, contains(capStreamTransport));
    });

    test(
      'routes the stream rung through AWG with the transport spec',
      () async {
        // The stream rung always runs on the AWG host, even for a stock inner
        // config: that host owns the VpnService the bridge protects its TLS
        // socket through, and its engine parses a stock config unchanged.
        final tunnel = HangingTunnel([]);
        final adapter = AndroidTunnelAdapter(
          stock: WireGuardTunnelAdapter.test(tunnel),
        );
        Map<String, Object?>? startArgs;
        messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, (
          call,
        ) async {
          if (call.method == 'startAwg') {
            startArgs = Map<String, Object?>.from(call.arguments as Map);
          }
          return <String, Object?>{'up': call.method == 'startAwg'};
        });
        const transport = TunnelTransport(
          listen: '127.0.0.1:51821',
          deliver: '127.0.0.1:51822',
          credential: StreamTransport(
            server: 'node.example:443',
            serverName: 'node.example',
            spkiPins: ['pin'],
            psk: 'psk',
            clientId: 'cid',
          ),
        );

        await adapter.start(
          serverAddress: '198.51.100.1',
          wgQuickConfig: stockConfig,
          providerBundleId: '',
          transport: transport,
        );

        expect(tunnel.configs, isEmpty);
        final spec = jsonDecode(
          startArgs!['streamSpec'] as String,
        ) as Map<String, Object?>;
        expect(spec['mode'], 'stream');
        expect(spec['listen'], '127.0.0.1:51821');
        expect(spec['deliver'], '127.0.0.1:51822');
        expect(spec['server'], 'node.example:443');
        expect(spec['server_name'], 'node.example');
        expect(spec['spki_sha256'], ['pin']);
      },
    );

    test(
      'reads liveness and the handshake from the active AWG backend',
      () async {
        final adapter = AndroidTunnelAdapter(
          stock: WireGuardTunnelAdapter.test(HangingTunnel([])),
        );
        messenger.setMockMethodCallHandler(
          AndroidTunnelAdapter.awgChannel,
          (call) async => <String, Object?>{
            'up': true,
            'stage': 'connected',
            'lastHandshake': 1_800_000_000,
            'rxBytes': 17,
            'txBytes': 23,
            'publicKey': 'server-key',
            'endpoint': '127.0.0.1:51820',
          },
        );

        expect(await adapter.readStage(), VpnStage.connected);
        expect(await adapter.readTraffic(), {'rxBytes': 17, 'txBytes': 23});
        expect(
          await adapter.readHandshake(),
          DateTime.fromMillisecondsSinceEpoch(1_800_000_000_000, isUtc: true),
        );
        final peer = await adapter.getActivePeer();
        expect(peer?.publicKey, 'server-key');
        expect(peer?.endpoint, '127.0.0.1:51820');
      },
    );
  });
}
