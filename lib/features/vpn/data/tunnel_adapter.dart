import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

import '../../../core/log.dart';
import 'helper_socket_stub.dart'
    if (dart.library.io) 'helper_socket_io.dart'
    as helper_platform;
import 'helper_tunnel_adapter.dart';
import 'platform_info.dart';
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
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
  });

  /// Graceful teardown with an automated hard-kill retry. Never throws.
  Future<void> stop(String reason);

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

  /// Ghost-aware tunnel helpers (Android `MainActivity`/`TunnelHost`).
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
  }) async {
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

/// Selects the tunnel backend for the current platform. Linux and Windows use
/// the privileged `boltmeshd` helper so the app process never holds
/// privilege; every other platform keeps the `wireguard_flutter_plus` plugin.
final tunnelAdapterProvider = Provider<TunnelAdapter>(
  (_) => helper_platform.isHelperPlatformSupported
      ? HelperTunnelAdapter()
      : WireGuardTunnelAdapter(),
);
