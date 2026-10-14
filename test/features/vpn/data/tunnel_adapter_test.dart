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

  test('an injected handshake reader is used', () async {
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

  test('no reader resolves as unknown, never throws', () async {
    // The plugin path has no native handshake source, so the read is absence
    // of evidence rather than a stall.
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

    expect(await adapter.readHandshake(), isNull);
  });

  test('the plugin path reports no active peer', () async {
    // The plugin exposes no peer identity and no host channel answers one, so
    // a cold restore here clean-bounces rather than adopting.
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

    expect(await adapter.getActivePeer(), isNull);
  });

  test('killGhost is a no-op false on the plugin path', () async {
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));

    expect(await adapter.killGhost(), isFalse);
  });

  test('requestConsent is a no-op on every platform it serves', () async {
    // Apple negotiates through its Network Extension and web has no tunnel;
    // neither pops a system dialog. Android's consent belongs to
    // AndroidTunnelAdapter, covered below.
    final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));
    final original = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = original);

    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(await adapter.requestConsent(), isTrue, reason: '$platform');
    }
  });

  group('handshakeReaderSupported', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('false without an injected reader, on every platform', () {
      final adapter = WireGuardTunnelAdapter.test(HangingTunnel([]));
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          adapter.handshakeReaderSupported,
          isFalse,
          reason: '$platform has no host handshake channel',
        );
      }
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

    test('runs obfuscated and stock configs on the AWG host alike', () async {
      // One Go runtime, always: the stock plugin's backend is never touched,
      // because constructing it loads a second Go runtime that faults the
      // process on the next stock tunnel.
      final adapter = AndroidTunnelAdapter();
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

      calls.clear();
      await adapter.start(
        serverAddress: '198.51.100.1',
        wgQuickConfig: stockConfig,
        providerBundleId: '',
      );
      expect(calls, ['stopAwg', 'startAwg']);
    });

    test('advertises the stream capability of its native bridge', () {
      final adapter = AndroidTunnelAdapter();
      expect(adapter.daemonCapabilities, contains(capStreamTransport));
    });

    // The consent contract the Android host must satisfy. This is the path
    // production runs (the plugin adapter never brokers Android consent), so
    // the fail-closed cases live here rather than on a WireGuard copy.
    group('requestConsent', () {
      test('asks the AWG host channel exactly once', () async {
        final adapter = AndroidTunnelAdapter();
        final calls = <String>[];
        messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, (
          call,
        ) async {
          calls.add(call.method);
          return true;
        });

        expect(await adapter.requestConsent(), isTrue);
        expect(calls, ['requestVpnConsent']);
      });

      test('returns the host answer', () async {
        for (final granted in [true, false]) {
          final adapter = AndroidTunnelAdapter();
          messenger.setMockMethodCallHandler(
            AndroidTunnelAdapter.awgChannel,
            (call) async => granted,
          );

          expect(await adapter.requestConsent(), granted);
        }
      });

      test('a null host answer counts as granted', () async {
        // Android with no VpnService to consent to must not read as denied.
        final adapter = AndroidTunnelAdapter();
        messenger.setMockMethodCallHandler(
          AndroidTunnelAdapter.awgChannel,
          (call) async => null,
        );

        expect(await adapter.requestConsent(), isTrue);
      });

      test('a missing host answers granted, deferring to start', () async {
        // No native host: there is no dialog to show, and `start` fails on its
        // own terms if the platform is genuinely wrong.
        final adapter = AndroidTunnelAdapter();
        messenger.setMockMethodCallHandler(
          AndroidTunnelAdapter.awgChannel,
          null,
        );

        expect(await adapter.requestConsent(), isTrue);
      });

      test('a failing host answers denied rather than throwing', () async {
        // Fail closed: reporting "granted" would push the dialog back inside
        // `start`'s budget, the exact failure this split exists to avoid.
        final adapter = AndroidTunnelAdapter();
        messenger.setMockMethodCallHandler(
          AndroidTunnelAdapter.awgChannel,
          (call) async => throw PlatformException(code: 'NO_ACTIVITY'),
        );

        expect(await adapter.requestConsent(), isFalse);
      });
    });

    test(
      'routes the stream rung through AWG with the transport spec',
      () async {
        // The stream rung points the peer endpoint at the bridge's loopback
        // address; the AWG host owns the VpnService the bridge protects its
        // TLS socket through, and its engine parses a stock config unchanged.
        final adapter = AndroidTunnelAdapter(
          resolveStreamServer: (server) async {
            expect(server, 'node.example:443');
            return '203.0.113.9:443';
          },
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

        final spec = jsonDecode(
          startArgs!['streamSpec'] as String,
        ) as Map<String, Object?>;
        expect(spec['mode'], 'stream');
        expect(spec['listen'], '127.0.0.1:51821');
        expect(spec['deliver'], '127.0.0.1:51822');
        // Resolved before the native start, while the TUN is down: the bridge
        // dials a literal address and never resolves through the tunnel it
        // carries. The hostname survives only as the TLS SNI/verification name.
        expect(spec['server'], '203.0.113.9:443');
        expect(spec['server_name'], 'node.example');
        expect(spec['spki_sha256'], ['pin']);
      },
    );

    test('stops the native tunnel when a stream start fails', () async {
      // A start the controller has given up on must not leave a live TUN
      // behind, or the app and the device start disagreeing about the state.
      final adapter = AndroidTunnelAdapter(
        resolveStreamServer: (_) async => '203.0.113.9:443',
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(AndroidTunnelAdapter.awgChannel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'startAwg') {
          throw PlatformException(code: 'AWG_START_FAILED');
        }
        return <String, Object?>{};
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

      await expectLater(
        adapter.start(
          serverAddress: '198.51.100.1',
          wgQuickConfig: stockConfig,
          providerBundleId: '',
          transport: transport,
        ),
        throwsA(isA<PlatformException>()),
      );

      expect(calls, ['stopAwg', 'startAwg', 'stopAwg']);
    });

    test(
      'reads liveness and the handshake from the active AWG backend',
      () async {
        final adapter = AndroidTunnelAdapter();
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

    test('reports unknown, then disconnected, with no AWG status', () async {
      final adapter = AndroidTunnelAdapter();
      // Nothing known to have been up: unknown, not dead.
      expect(await adapter.readStage(), isNull);
      expect(await adapter.readTraffic(), isNull);

      // Come up, then lose the status channel: the last known rung was up, so
      // the read is a disconnect rather than an unknown stall.
      messenger.setMockMethodCallHandler(
        AndroidTunnelAdapter.awgChannel,
        (call) async => <String, Object?>{'up': true, 'stage': 'connected'},
      );
      expect(await adapter.readStage(), VpnStage.connected);

      messenger.setMockMethodCallHandler(
        AndroidTunnelAdapter.awgChannel,
        (call) async => null,
      );
      expect(await adapter.readStage(), VpnStage.disconnected);
    });

    test('reads the stream session state from the AWG backend', () async {
      final adapter = AndroidTunnelAdapter();
      // A live stream transport reports its session state: false while
      // the bridge's TLS session is still establishing, true once it
      // has completed. The health tick reads this to keep a rung still
      // coming up from reading as a dead path.
      messenger.setMockMethodCallHandler(
        AndroidTunnelAdapter.awgChannel,
        (call) async => <String, Object?>{
          'up': true,
          'stage': 'connected',
          'lastHandshake': 0,
          'streamSession': false,
        },
      );
      expect(await adapter.readStreamSession(), isFalse);

      messenger.setMockMethodCallHandler(
        AndroidTunnelAdapter.awgChannel,
        (call) async => <String, Object?>{
          'up': true,
          'stage': 'connected',
          'lastHandshake': 1_800_000_000,
          'streamSession': true,
        },
      );
      expect(await adapter.readStreamSession(), isTrue);

      // Absent means the tunnel is on a native or obfuscated rung,
      // which has no stream session to report.
      messenger.setMockMethodCallHandler(
        AndroidTunnelAdapter.awgChannel,
        (call) async => <String, Object?>{'up': true, 'stage': 'connected'},
      );
      expect(await adapter.readStreamSession(), isNull);
    });
  });
}
