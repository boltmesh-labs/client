import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import '../../../core/log.dart';
import 'helper_client.dart' show capStreamTransport;
import 'helper_socket_stub.dart'
    if (dart.library.io) 'helper_socket_io.dart'
    as helper_platform;
import 'helper_tunnel_adapter.dart';
import 'platform_info.dart';
import 'stream_server_resolver_stub.dart'
    if (dart.library.io) 'stream_server_resolver_io.dart'
    as stream_resolver;
import 'stream_transport.dart';
import 'tunnel_tuning.dart';

/// True where the plugin has no handshake source of its own and the native
/// `com.boltmesh/handshake` host channel answers it (Android). Linux and
/// Windows read handshakes from the `boltmeshd` helper instead.
bool get _hostHandshakeSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Reads the last completed WireGuard handshake. Null means "unknown"
/// and must never be treated as a stall on its own.
typedef HandshakeReader = Future<DateTime?> Function();

/// Identifying fields of the tunnel's live peer, without private key
/// material. Enough to decide adopt-if-match vs clean bounce after an
/// engine restart (see `MainActivity.kt`).
class ActivePeer {
  const ActivePeer({required this.publicKey, required this.endpoint});

  /// Server WireGuard public key (base64).
  final String publicKey;

  /// `host:port` of the peer endpoint.
  final String endpoint;
}

/// Native tunnel primitives behind a narrow interface.
///
/// Extracted from [ConnectionController] so tunnel timeouts, the
/// stop-retry, and the `WireGuardFlutter.instance` lazy lookup live in one
/// place. The controller keeps orchestration (which op runs when); this
/// class only talks to the OS plugin. All reads are nullable: null means
/// "unknown" and must never be treated as a stall on its own.
abstract class TunnelAdapter {
  /// True once [ensureInitialized] has succeeded.
  bool get isReady;

  /// OS-side stage events (empty when the plugin has no channel).
  Stream<VpnStage> get stages;

  /// Idempotent plugin setup. Throws on failure.
  Future<void> ensureInitialized();

  /// Starts the tunnel. Throws on failure/timeout.
  /// [providerBundleId] is the Apple Network-Extension bundle ID
  /// (iOS/macOS only); pass `''` on every other platform, where the
  /// plugin ignores it. Use `resolveProviderBundleId()` to build it.
  ///
  /// [transport] is set only for the stream rung, and only where
  /// [daemonCapabilities] offers the stream token — see
  /// [streamTransportSupported]. An adapter that cannot run a transport must
  /// throw rather than ignore it: the conf already points its peer at the
  /// bridge's loopback address, so ignoring the spec would bring the tunnel up
  /// on an endpoint nothing is listening on.
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
    TunnelTransport? transport,
  });

  /// Capability tokens the backing data plane advertises. Empty when there is
  /// no daemon (the plugin path), which is why it is safe to gate a rung on:
  /// "no daemon" reads as "no transport support". The Android adapter is the
  /// exception — it has no daemon either, but its in-process native bridge can
  /// run the stream transport, so it advertises the same token.
  Set<String> get daemonCapabilities => const <String>{};

  /// Graceful teardown with an automated hard-kill retry. Never throws.
  Future<void> stop(String reason);

  /// Ensures the OS has authorized this app to run a VPN tunnel, showing the
  /// system consent dialog when consent has not been granted yet. False when
  /// the user declines.
  ///
  /// Split from [start] deliberately. Consent is an unbounded human
  /// interaction with a system dialog, while [start] is bounded by
  /// `TunnelTuning.opTimeout` to catch a wedged driver. Folding the two
  /// together makes a slow "OK" tap indistinguishable from a driver hang, so
  /// the first connect after every fresh install reports a bogus timeout
  /// failure and only succeeds on a second tap.
  ///
  /// Platforms with no consent step — Linux/Windows (privileged `boltmeshd`
  /// helper) and Apple (Network Extension negotiation) — return true without
  /// doing anything. Never throws: a denial is a user decision, not a fault.
  Future<bool> requestConsent() async => true;

  /// Current OS stage, or null when unreadable.
  Future<VpnStage?> readStage();

  /// Raw `trafficStats()` map, or null when unreadable. Display-only: heal
  /// decisions use [readHandshake], never byte counters.
  Future<Map<String, dynamic>?> readTraffic();

  /// Last completed WireGuard handshake, or null when unknown (unreadable
  /// IPC, or the native reader not yet implemented on this platform).
  /// Never throws.
  Future<DateTime?> readHandshake();

  /// The live peer of the owning tunnel (the backend whose
  /// `runningTunnelNames` is non-empty, surviving engine restarts), or null
  /// when no tunnel is running or the platform has no ghost-aware channel.
  /// Never throws.
  Future<ActivePeer?> getActivePeer();

  /// Brings the owning tunnel DOWN directly (same backend object identity),
  /// including a pre-restart ghost the plugin lost its handle to. Idempotent:
  /// true when no tunnel is running afterwards. Never throws and never
  /// starts a tunnel.
  Future<bool> killGhost();

  /// True when [readHandshake] can actually observe the peer: Linux and
  /// Windows (the `boltmeshd` helper), Android (the `com.boltmesh/handshake`
  /// host channel), or an injected reader. There a null read means "no
  /// handshake yet". On unsupported platforms the read is always null —
  /// absence of evidence — and `isHandshakeStale`'s never-handshook branch
  /// must not fire.
  bool get handshakeReaderSupported;
}

/// [TunnelAdapter] over `wireguard_flutter_plus`.
///
/// `instance` is resolved lazily because the plugin throws
/// UnsupportedError on unsupported platforms (web).
///
/// `wireguard_flutter_plus` exposes only byte counters, so handshakes come
/// from our own channel (the plugin is never forked): Android's `MainActivity`
/// answers the `com.boltmesh/handshake` host channel with the GoBackend peer
/// `latestHandshakeEpochMillis`. Linux and Windows do not use this adapter at
/// all (they run through the privileged `boltmeshd` helper, see
/// [HelperTunnelAdapter]). Apple still asks the host channel as a placeholder
/// for its future handler (see `client/README.md`) — there a missing handler
/// resolves as unknown, and [handshakeReaderSupported] reports false so the
/// null never counts as a never-handshook stall.
class WireGuardTunnelAdapter implements TunnelAdapter {
  WireGuardTunnelAdapter() : _handshakeReader = null;

  /// Pre-initialized adapter for tests (skips plugin `initialize()`).
  WireGuardTunnelAdapter.test(
    WireGuardFlutterInterface raw, {
    this._handshakeReader,
  }) : _raw = raw,
       _initialized = true;

  /// Test adapter with a pre-supplied plugin but initialization still
  /// pending, so [ensureInitialized] actually runs (and its arguments can be
  /// observed) without reaching `WireGuardFlutter.instance`, which throws off
  /// a real platform.
  @visibleForTesting
  factory WireGuardTunnelAdapter.testUninitialized(
    WireGuardFlutterInterface raw, {
    HandshakeReader? handshakeReader,
  }) {
    final adapter = WireGuardTunnelAdapter.test(
      raw,
      handshakeReader: handshakeReader,
    );
    adapter._initialized = false;
    return adapter;
  }

  /// Own host channel for handshake reads (never the VPN plugin's).
  /// Missing handler (web, or a platform whose native code hasn't landed)
  /// resolves as unknown, never as a stall.
  @visibleForTesting
  static const handshakeChannel = MethodChannel('com.boltmesh/handshake');

  /// Tunnel helpers on the app's own host channel (Android
  /// `MainActivity`/`TunnelHost`): ghost-aware tunnel control and VPN consent.
  @visibleForTesting
  static const ghostChannel = MethodChannel('com.boltmesh/tunnel');

  WireGuardFlutterInterface? _raw;
  final HandshakeReader? _handshakeReader;

  /// Test seam: counts [killGhost] calls.
  int ghostKills = 0;
  bool _initialized = false;

  @override
  bool get isReady => _initialized && _raw != null;

  @override
  bool get handshakeReaderSupported =>
      _handshakeReader != null || _hostHandshakeSupported;

  /// No daemon on this path — the plugin owns the data plane — so no
  /// capability tokens. An explicit override because `implements` does not
  /// inherit the interface's default body; the empty set is what keeps a
  /// daemon-gated rung from ever selecting itself here.
  @override
  Set<String> get daemonCapabilities => const <String>{};

  @override
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    final wg = _raw ?? WireGuardFlutter.instance;
    // `iosAppGroup` is the App Group the Packet Tunnel extension reads the
    // wgQuick config from. Omitting it makes the plugin fall back to
    // `group.orbanvpn.wireguard`, which is in no provisioning profile — the
    // connect then fails inside the extension with an opaque error. Resolved
    // through `resolveAppGroup()` so Apple fails fast with a named define.
    await wg.initialize(
      interfaceName: 'boltmesh0',
      vpnName: 'BoltMesh VPN',
      iosAppGroup: resolveAppGroup(),
    );
    _raw = wg;
    _initialized = true;
  }

  @override
  Stream<VpnStage> get stages {
    final wg = _raw;
    if (wg == null) return const Stream.empty();
    try {
      return wg.vpnStageSnapshot;
    } catch (e) {
      AppLog.error('tunnel stage subscription unavailable', e);
      return const Stream.empty();
    }
  }

  @override
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
    TunnelTransport? transport,
  }) async {
    // Fail closed rather than ignore: the caller only sets a transport when
    // the helper is the one that can run it, so reaching here means the gate
    // and this adapter disagree — and starting the tunnel anyway would point
    // its peer at a loopback address nothing is bound to.
    if (transport != null) {
      throw UnsupportedError(
        'This platform cannot run a stream transport; the plugin data plane '
        'has no transport lifecycle.',
      );
    }
    final wg = _raw;
    if (wg == null) {
      throw StateError('VPN tunnel is unavailable on this platform.');
    }
    await wg
        .startVpn(
          serverAddress: serverAddress,
          wgQuickConfig: wgQuickConfig,
          providerBundleIdentifier: providerBundleId,
        )
        .timeout(TunnelTuning.opTimeout);
  }

  /// Asks the OS for VPN consent through the app's own `com.boltmesh/tunnel`
  /// host channel, so the system dialog is answered *before* [start]'s
  /// wedged-driver budget applies.
  ///
  /// Must run before [ensureInitialized]: the plugin's `initialize()` calls
  /// `VpnService.prepare` itself and pops the dialog from there, and its
  /// `startVpn` then blocks until the user answers — inside the very timeout
  /// this split exists to keep clear. Once consent exists, both of the
  /// plugin's own `prepare` calls return null and show nothing, so the user
  /// still sees exactly one dialog.
  ///
  /// The plugin's own `checkVpnPermission()` is deliberately not used: it
  /// stores its pending `MethodChannel.Result` in a field that
  /// `onActivityResult` never completes, so that future hangs forever
  /// whenever consent is actually missing.
  @override
  Future<bool> requestConsent() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await ghostChannel.invokeMethod<bool>('requestVpnConsent') ?? true;
    } on MissingPluginException {
      // No native host (plain `flutter test`): there is nothing to consent
      // to, and `start` will fail on its own terms if the platform is wrong.
      return true;
    } catch (e) {
      // Fail closed. Guessing "granted" would push the dialog back inside
      // `start`'s timeout, which is the exact failure this split avoids.
      AppLog.error('vpn consent request failed', e);
      return false;
    }
  }

  @override
  Future<void> stop(String reason) async {
    final wg = _raw;
    if (wg == null) return;
    try {
      await wg.stopVpn().timeout(TunnelTuning.stopTimeout);
      AppLog.info('tunnel stopped ($reason)');
      return;
    } on TimeoutException catch (e) {
      AppLog.error('tunnel stop timed out ($reason), hard-kill retry', e);
    } catch (e) {
      // Tunnel may already be down; a retry is still cheap and harmless.
      AppLog.error('tunnel stop failed ($reason), hard-kill retry', e);
    }
    try {
      await wg.stopVpn().timeout(TunnelTuning.stopTimeout);
      AppLog.info('tunnel stopped on retry ($reason)');
    } on TimeoutException catch (e) {
      AppLog.error(
        'tunnel stop retry timed out ($reason), forcing local teardown',
        e,
      );
    } catch (e) {
      AppLog.error('tunnel stop retry failed ($reason)', e);
    }
  }

  @override
  Future<VpnStage?> readStage() async {
    final wg = _raw;
    if (wg == null) return null;
    try {
      return await wg.stage().timeout(TunnelTuning.healthTimeout);
    } on TimeoutException catch (e) {
      // Transient (e.g. Wintun counters not queryable yet right after
      // start): null means unknown, never a stall on its own. Logged at
      // info (not error) so a wedged stats IPC can't masquerade as a dead
      // tunnel while traffic still flows (server heartbeats are truth).
      AppLog.info('health stage read timed out (unknown, ignoring): $e');
      return null;
    } catch (e) {
      AppLog.error('health stage read failed', e);
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> readTraffic() async {
    final wg = _raw;
    if (wg == null) return null;
    try {
      return await wg.trafficStats().timeout(TunnelTuning.healthTimeout);
    } on TimeoutException catch (e) {
      // Transient (e.g. Wintun counters not queryable yet right after
      // start): null means unknown, never a stall on its own. Logged at
      // info (not error) so a wedged stats IPC can't masquerade as a dead
      // tunnel while traffic still flows (server heartbeats are truth).
      AppLog.info('health traffic read timed out (unknown, ignoring): $e');
      return null;
    } catch (e) {
      AppLog.error('health traffic read failed', e);
      return null;
    }
  }

  @override
  Future<DateTime?> readHandshake() async {
    final reader = _handshakeReader;
    if (reader != null) {
      try {
        return await reader().timeout(TunnelTuning.healthTimeout);
      } catch (e) {
        AppLog.error('health handshake read failed', e);
        return null;
      }
    }
    try {
      final epochSecs = await handshakeChannel
          .invokeMethod<num?>('getLastHandshake')
          .timeout(TunnelTuning.healthTimeout);
      if (epochSecs == null || epochSecs <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (epochSecs * 1000).toInt(),
        isUtc: true,
      );
    } catch (e) {
      // No native handler yet on this platform (or web): unknown, never a
      // stall on its own. The degraded-stage path still heals those cases.
      AppLog.info('health handshake unavailable (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<ActivePeer?> getActivePeer() async {
    try {
      final m = await ghostChannel
          .invokeMapMethod<String, dynamic>('getActivePeer')
          .timeout(TunnelTuning.healthTimeout);
      if (m == null) return null;
      final pub = (m['publicKey'] as String?)?.trim() ?? '';
      if (pub.isEmpty) return null;
      return ActivePeer(
        publicKey: pub,
        endpoint: (m['endpoint'] as String?)?.trim() ?? '',
      );
    } catch (e) {
      // No native handler on this platform (or under `flutter test`):
      // unknown, never a stall on its own.
      AppLog.info('ghost active-peer unavailable (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<bool> killGhost() async {
    ghostKills++;
    try {
      final ok = await ghostChannel
          .invokeMethod<bool>('killGhost')
          .timeout(TunnelTuning.opTimeout);
      return ok ?? false;
    } catch (e) {
      // No native handler on this platform (or under `flutter test`):
      // the plain stop above already ran; nothing more to kill.
      AppLog.info('ghost kill unavailable (ignoring): $e');
      return false;
    }
  }
}

/// Android can use two in-process Go backends: the existing plugin for stock
/// WireGuard and BoltMesh's AWG host for obfuscated regions. This adapter
/// selects by config shape and keeps status/teardown directed to the backend
/// that currently owns Android's single VpnService TUN.
class AndroidTunnelAdapter implements TunnelAdapter {
  AndroidTunnelAdapter({
    WireGuardTunnelAdapter? stock,
    Future<String> Function(String server)? resolveStreamServer,
  }) : _stock = stock ?? WireGuardTunnelAdapter(),
       _resolveStreamServer =
           resolveStreamServer ?? stream_resolver.resolveStreamServer;

  final WireGuardTunnelAdapter _stock;

  /// Resolves the stream node's host to a literal address before the start.
  /// Injectable so the hand-off is testable without a real lookup.
  final Future<String> Function(String server) _resolveStreamServer;

  bool _awgActive = false;

  @visibleForTesting
  static const awgChannel = MethodChannel('com.boltmesh/tunnel');

  static final _awgDirective = RegExp(
    r'^\s*Jc\s*=',
    caseSensitive: false,
    multiLine: true,
  );

  @override
  bool get isReady => _stock.isReady;

  @override
  Stream<VpnStage> get stages => const Stream<VpnStage>.empty();

  @override
  Future<void> ensureInitialized() => _stock.ensureInitialized();

  /// Android has no privileged daemon, but its in-process native bridge is a
  /// real stream data plane, so it advertises the token the ladder gates on.
  /// Without it `_streamRungAvailable` would never offer the rung here even
  /// though the bridge can run it.
  @override
  Set<String> get daemonCapabilities => const <String>{capStreamTransport};

  @override
  bool get handshakeReaderSupported => true;

  @override
  Future<bool> requestConsent() => _stock.requestConsent();

  @override
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
    TunnelTransport? transport,
  }) async {
    // The stream rung points the peer endpoint at the bridge's loopback
    // address. It always runs on the AWG host — the in-process engine that
    // owns the VpnService the bridge protects its TLS socket through — even
    // when the inner config is stock: the plugin's data plane owns its own
    // VpnService and cannot carry the bridge. The AWG engine parses a stock
    // config unchanged (every obfuscation directive defaults off).
    if (transport != null || _awgDirective.hasMatch(wgQuickConfig)) {
      // Android allows one owning VPN TUN. Tear down either previous engine
      // before transferring ownership to the other one — and before resolving
      // the node, so the query cannot follow a still-live tunnel.
      await _stopAwg('restart Android AWG tunnel');
      await _stock.stop('switch Android VPN owner to AWG');
      final spec = transport?.toSpecJson();
      if (spec != null) {
        // Hand the bridge a literal address: once the TUN exists the app's
        // resolver follows it, so the node's hostname would resolve through
        // the very tunnel the bridge is needed to bring up. Resolving here,
        // before the native start, keeps the query on the physical network.
        spec['server'] = await _resolveStreamServer(spec['server']! as String);
      }
      try {
        await awgChannel
            .invokeMapMethod<String, Object?>('startAwg', <String, Object?>{
              'wgQuickConfig': wgQuickConfig,
              if (spec != null) 'streamSpec': jsonEncode(spec),
            })
            .timeout(TunnelTuning.opTimeout);
      } catch (_) {
        // A failed or timed-out start must not leave a live TUN behind that
        // the controller has already given up on, or the app and the device
        // disagree about the connection. The native side serializes stop
        // after an in-flight start, so this cannot race the start's cleanup.
        await _stopAwg('start failed');
        rethrow;
      }
      _awgActive = true;
      return;
    }

    await _stopAwg('switch Android VPN owner to stock WireGuard');
    await _stock.start(
      serverAddress: serverAddress,
      wgQuickConfig: wgQuickConfig,
      providerBundleId: providerBundleId,
    );
    _awgActive = false;
  }

  @override
  Future<void> stop(String reason) async {
    await _stopAwg(reason);
    await _stock.stop(reason);
    _awgActive = false;
  }

  Future<void> _stopAwg(String reason) async {
    try {
      await awgChannel
          .invokeMapMethod<String, Object?>('stopAwg')
          .timeout(TunnelTuning.stopTimeout);
      AppLog.info('Android AWG tunnel stopped ($reason)');
    } catch (e) {
      // The AWG backend may never have been initialized. It is safe to proceed
      // to the stock backend, but retain unknown rather than claiming success.
      AppLog.info('Android AWG stop unavailable ($reason): $e');
    }
  }

  Future<Map<String, Object?>?> _readAwgStatus() async {
    try {
      return await awgChannel
          .invokeMapMethod<String, Object?>('statusAwg')
          .timeout(TunnelTuning.healthTimeout);
    } catch (e) {
      AppLog.info('Android AWG status unavailable (unknown, ignoring): $e');
      return null;
    }
  }

  bool _isUp(Map<String, Object?> status) => status['up'] == true;

  VpnStage _stage(Map<String, Object?> status) => switch (status['stage']) {
    'connected' => VpnStage.connected,
    'connecting' => VpnStage.connecting,
    _ => VpnStage.disconnected,
  };

  @override
  Future<VpnStage?> readStage() async {
    final status = await _readAwgStatus();
    if (status != null && _isUp(status)) {
      _awgActive = true;
      return _stage(status);
    }
    if (_awgActive) {
      _awgActive = false;
      return VpnStage.disconnected;
    }
    return _stock.readStage();
  }

  @override
  Future<Map<String, dynamic>?> readTraffic() async {
    final status = await _readAwgStatus();
    if (status != null && _isUp(status)) {
      _awgActive = true;
      return <String, dynamic>{
        'rxBytes': status['rxBytes'] ?? 0,
        'txBytes': status['txBytes'] ?? 0,
      };
    }
    if (_awgActive) {
      _awgActive = false;
      return null;
    }
    return _stock.readTraffic();
  }

  @override
  Future<DateTime?> readHandshake() async {
    final status = await _readAwgStatus();
    if (status != null && _isUp(status)) {
      _awgActive = true;
      final seconds = status['lastHandshake'];
      if (seconds is! num || seconds <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000).toInt(),
        isUtc: true,
      );
    }
    if (_awgActive) {
      _awgActive = false;
      return null;
    }
    return _stock.readHandshake();
  }

  @override
  Future<ActivePeer?> getActivePeer() async {
    final status = await _readAwgStatus();
    if (status != null && _isUp(status)) {
      _awgActive = true;
      final publicKey = (status['publicKey'] as String?)?.trim() ?? '';
      if (publicKey.isEmpty) return null;
      return ActivePeer(
        publicKey: publicKey,
        endpoint: (status['endpoint'] as String?)?.trim() ?? '',
      );
    }
    if (_awgActive) {
      _awgActive = false;
      return null;
    }
    return _stock.getActivePeer();
  }

  @override
  Future<bool> killGhost() async {
    var awgKilled = false;
    try {
      awgKilled =
          await awgChannel
              .invokeMethod<bool>('killAwgGhost')
              .timeout(TunnelTuning.opTimeout) ??
          false;
    } catch (e) {
      AppLog.info('Android AWG ghost kill unavailable (ignoring): $e');
    }
    _awgActive = false;
    final stockKilled = await _stock.killGhost();
    return awgKilled && stockKilled;
  }
}

/// Selects the tunnel backend for the current platform. Linux and Windows use
/// the privileged `boltmeshd` helper so the app process never holds
/// privilege; every other platform keeps the `wireguard_flutter_plus` plugin.
final tunnelAdapterProvider = Provider<TunnelAdapter>((_) {
  if (helper_platform.isHelperPlatformSupported) return HelperTunnelAdapter();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidTunnelAdapter();
  }
  return WireGuardTunnelAdapter();
});
