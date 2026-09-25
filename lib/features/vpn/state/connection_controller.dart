import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../core/clock.dart';
import '../../../core/dio_client.dart';
import '../../../core/env.dart';
import '../../../core/errors.dart';
import '../../../core/log.dart';
import '../../../core/mutex.dart';
import '../../auth/data/session_store.dart';
import '../../auth/state/auth_providers.dart';
import '../data/control_probe.dart';
import '../data/device_store.dart';
import '../data/gateway_probe.dart';
import '../data/key_manager.dart';
import '../data/models.dart';
import '../data/network_monitor.dart';
import '../data/platform_info.dart';
import '../data/tunnel_adapter.dart';
import '../data/tunnel_tuning.dart';
import '../data/vpn_api.dart';
import '../data/wg_conf.dart';
import '../domain/backend_issue.dart';
import '../domain/diagnosis_policy.dart';
import '../domain/failover_policy.dart';
import '../domain/region_policy.dart';
import '../domain/tunnel_policy.dart';
import 'cold_restore_watch.dart';
import 'connection_state.dart';
import 'connection_tuning.dart';
import 'polling_service.dart';

export 'connection_state.dart';

part 'conn_coldstart.dart';
part 'conn_connect.dart';
part 'conn_health.dart';
part 'conn_lifecycle.dart';
part 'conn_poll.dart';
part 'conn_provision.dart';
part 'conn_recovery.dart';
part 'conn_stage.dart';
part 'conn_switch.dart';
part 'conn_transport.dart';
part 'conn_tunnel.dart';

/// Orchestrates provision → connect/switch → disconnect with fresh
/// keypairs per handshake (backend 409s on key reuse).
class ConnectionController extends Notifier<ConnState> {
  VpnApi get _api => ref.read(vpnApiProvider);
  DeviceStore get _device => ref.read(deviceStoreProvider);
  KeyManager get _keys => ref.read(keyManagerProvider);
  // Diagnostic-probe + UI providers read by the `conn_*.dart` parts. Riverpod
  // keeps `ref` `@protected` (the same reason [snap] wraps `state`), so the
  // extensions in those part files reach it only through these getters.
  NetworkMonitor get _networkMonitor => ref.read(networkMonitorProvider);
  GatewayProbe get _gatewayProbe => ref.read(gatewayProbeProvider);
  ControlPlaneProbe get _controlPlaneProbe =>
      ref.read(controlPlaneProbeProvider);
  // Wall clock behind every time window (handshake staleness, backend quiet,
  // cold-restore grace). Injectable so those windows are aged deterministically
  // in tests instead of by poking private anchors.
  Clock get _clock => ref.read(clockProvider);

  /// Re-reads the split-tunnel preference once [setAllowLocal] persisted it.
  void _invalidateAllowLocal() => ref.invalidate(allowLocalProvider);
  // Native tunnel behind [TunnelAdapter] (see `data/tunnel_adapter.dart`).
  // `_tunnelOverride` is test-only (via [debugTunnel]); production uses
  // [tunnelAdapterProvider]. The stage subscription is (re)built by
  // [_ensureTunnelInit] whenever the active tunnel changes.
  TunnelAdapter? _tunnelOverride;
  StreamSubscription<VpnStage>? _stageSub;

  /// OS link transitions (see [NetworkMonitor.linkChanges]); drives
  /// [_onLinkChanged] so a returning link heals at once instead of on the
  /// next health tick.
  StreamSubscription<bool>? _linkSub;

  TunnelAdapter get _tunnel =>
      _tunnelOverride ?? ref.read(tunnelAdapterProvider);

  /// Serializes connect/switch/disconnect so two `startVpn` calls can never
  /// interleave on Windows (Wintun) and wedge the default route.
  /// Waiters queue in FIFO order instead of being silently dropped.
  final AsyncMutex _mutex = AsyncMutex();

  /// Bumped on every tunnel teardown ([_stopTunnel]). Status polls capture
  /// it before `GET …/status` and drop the result when it changed: the
  /// socket died with the teardown (errno-10057), so the outcome proves
  /// nothing about the backend — even when the heal already flipped back
  /// to `connected` before the poll failed.
  int _tunnelEpoch = 0;

  /// Bumped whenever the authenticated session changes. Recovery operations
  /// capture it before any network/storage await and refuse to start a tunnel
  /// again after a revocation (or a subsequent login) has superseded them.
  int _sessionEpoch = 0;

  /// Bumped on every explicit teardown: Disconnect, Reset/Forget-device, and
  /// session revocation. A lock-free operation spanning awaits — Quick
  /// Connect discovery then probe/bind/start — captures it before its first
  /// await and refuses to dial once it changed, so a Disconnect tapped while
  /// discovery is in flight can never be undone by the earlier connect.
  /// Distinct from [_sessionEpoch] (auth transitions) and [_tunnelEpoch]
  /// (every tunnel stop, including internal restarts).
  int _teardownEpoch = 0;

  /// Background ticks (status poll + local health check); run only while
  /// connected (see [_startPolling]). Lifecycle owned by [PollingService].
  final PollingService _polling = PollingService();

  /// True when the most recent status request received an application-level
  /// response (including 401/403/409/429/5xx). A response proves the control
  /// plane was reachable even when it rejected the request, so health must
  /// not reinterpret it as a transport outage. Reset with the tunnel/session
  /// health anchor in [_resetLocalHealth].
  bool _lastStatusAnswered = false;

  /// Shared single-flight guards for public/manual ticks as well as timer
  /// ticks. Resume catch-up calls the public methods directly, so the
  /// [PollingService] flags alone are not sufficient to prevent duplicate
  /// status requests or overlapping recovery probes.
  Future<void>? _statusPollInFlight;
  Future<void>? _healthCheckInFlight;

  /// True while the app is hidden (paused), driven by [ResumeCoordinator].
  /// Slows the health tick onto [PollingService.backgroundHealthCheckInterval]
  /// and skips the display-only traffic read, so a swiped-away tunnel keeps
  /// auto-healing at a fraction of the foreground wake rate.
  bool _backgrounded = false;

  /// When the current tunnel (re)started. Anchors the never-handshook
  /// branch of [isHandshakeStale]: a tunnel that completes no handshake
  /// within the grace window (supported reader) is dead, while null before
  /// that is just unknown (slow handshake, wedged IPC, missing native
  /// reader — which never counts at all, see the readerSupport gate).
  DateTime? _connectedAt;

  /// Consecutive health ticks whose in-tunnel gateway echo was
  /// *performed-dead* (`false`, never null). Reaching
  /// [ConnectionTuning.echoStallStrikes] shortens the dead-peer handshake
  /// window to [ConnectionTuning.echoStallHandshakeAge], so a data-path
  /// death is caught sooner than the full rekey cycle. The echo is only
  /// read once the handshake is old enough to matter (see
  /// [ConnectionTuning.echoProbeAfter]); a skipped probe clears the run,
  /// as does any alive/unknown echo, a successful status poll (backend
  /// proven reachable through the tunnel), and a tunnel restart
  /// ([_resetLocalHealth]).
  int _deadEchoStrikes = 0;

  /// Test seam: inspect/prime the dead-echo strike counter.
  @visibleForTesting
  int get debugDeadEchoStrikes => _deadEchoStrikes;
  @visibleForTesting
  set debugDeadEchoStrikes(int v) => _deadEchoStrikes = v;

  /// Test seam: overrides the handshake read (production uses
  /// [TunnelAdapter.readHandshake]).
  @visibleForTesting
  HandshakeReader? debugHandshakeReader;

  /// Test seam: overrides the live-peer read (production uses
  /// [TunnelAdapter.getActivePeer]).
  @visibleForTesting
  ActivePeer? debugActivePeer;

  /// Poll ticks since the last successful rotation; reaching
  /// [Env.keyRotationPolls] triggers an automatic background rotation.
  int _pollsSinceRotate = 0;

  /// Test seam: inspect/prime the auto-rotation counter.
  @visibleForTesting
  int get debugPollsSinceRotate => _pollsSinceRotate;
  @visibleForTesting
  set debugPollsSinceRotate(int v) => _pollsSinceRotate = v;

  /// Client-side cooldown armed by a 429 (`ApiErrorKind.rateLimited`). While
  /// active the API-mutating ops (connect/switch/rotate, and the disconnect
  /// peer release) short-circuit instead of spending more of the shared
  /// per-IP limiter budget. Expires on its own (see [_rateLimitRemaining]).
  DateTime? _rateLimitedUntil;

  /// Test seam: inspect/prime the 429 cooldown deadline.
  @visibleForTesting
  DateTime? get debugRateLimitedUntil => _rateLimitedUntil;
  @visibleForTesting
  set debugRateLimitedUntil(DateTime? v) => _rateLimitedUntil = v;

  /// Time left in the 429 cooldown, or null when not throttled.
  Duration? get _rateLimitRemaining {
    final until = _rateLimitedUntil;
    if (until == null) return null;
    final remaining = until.difference(_clock.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Test seam: bypasses `WireGuardFlutter.instance` (which throws on
  /// unsupported platforms) with a fake tunnel. The raw interface is
  /// wrapped in a pre-initialized [WireGuardTunnelAdapter], so existing
  /// `FakeTunnel` fakes keep working unchanged.
  @visibleForTesting
  set debugTunnel(WireGuardFlutterInterface? wg) {
    unawaited(_stageSub?.cancel());
    _stageSub = null;
    _tunnelOverride = wg == null ? null : WireGuardTunnelAdapter.test(wg);
  }

  /// Test seam: when non-null, forces the through-tunnel-first decision in
  /// [switchServer] (production reads [Env.isLoopbackApi], which is a
  /// compile-time const stuck on `localhost` under `flutter test`).
  @visibleForTesting
  bool? debugForceThroughTunnel;

  /// Test seam: holds the op mutex so resume catch-up lock-skips can be
  /// tested deterministically. Returns the one-shot release callback.
  @visibleForTesting
  Future<void Function()> debugAcquireMutex([String op = 'test']) =>
      _mutex.acquire(op);

  /// Cold-restore watch (see [reconcileColdStart]): armed while an
  /// unconfirmed restore waits on the stage stream, plus the server-truth
  /// confirm time that anchors the post-restore grace.
  final ColdRestoreWatch _coldRestore = ColdRestoreWatch();

  /// Test seam: observes the cold-restore watch.
  @visibleForTesting
  bool get debugColdWatchArmed => _coldRestore.armed;

  /// Test seam: observes/boards the cold-restore grace clock.
  @visibleForTesting
  DateTime? get debugColdRestoreConfirmedAt => _coldRestore.confirmedAt;
  @visibleForTesting
  set debugColdRestoreConfirmedAt(DateTime? v) => _coldRestore.confirmedAt = v;

  /// Read/write view of [Notifier.state] for the same-library operation
  /// parts (`conn_*.dart`). Extensions cannot reference the protected
  /// `state` directly, so all part code goes through here. UI and tests
  /// must keep using the providers, not this.
  ConnState get snap => state;
  set snap(ConnState s) => state = s;

  /// True while the session captured by [sessionEpoch]/[epoch] and dialing
  /// [dial] is still the live one — the guard every post-await recovery path
  /// re-checks before acting on a result.
  ///
  /// The four clauses are the whole contract, and they used to be spelled out
  /// inline at a dozen call sites. Centralizing them is what keeps them
  /// honest: a member added here (the `readerSupported` gate on
  /// [isHandshakeStale] was silently missing from three of them) is added
  /// everywhere at once, and a superseded path can no longer check a subset
  /// and act on a stale result.
  bool _sessionCurrent({
    required int sessionEpoch,
    required int epoch,
    required DialParams? dial,
  }) =>
      sessionEpoch == _sessionEpoch &&
      epoch == _tunnelEpoch &&
      snap.phase == ConnPhase.connected &&
      identical(snap.dial, dial);

  /// [_sessionCurrent] for callers that captured only *some* of the anchors
  /// (a lock-free discovery op that knows no tunnel epoch, or a public tick
  /// that may run before any tunnel exists). A null anchor is not checked —
  /// the check is skipped, never treated as a mismatch. Callers that do have
  /// every anchor should prefer [_sessionCurrent]: it is one expression
  /// rather than three independent early returns.
  bool _sessionStillMatches({
    int? sessionEpoch,
    int? epoch,
    DialParams? dial,
  }) =>
      (sessionEpoch == null || sessionEpoch == _sessionEpoch) &&
      (epoch == null || epoch == _tunnelEpoch) &&
      (dial == null || identical(snap.dial, dial));

  @override
  ConnState build() {
    ref.onDispose(() {
      unawaited(_stageSub?.cancel());
      unawaited(_linkSub?.cancel());
      _stopPolling();
    });
    // One-way session hook (VPN reads auth, never the reverse): an
    // involuntary sign-out (revoked/suspended refresh) must never orphan a
    // live tunnel or leak the device identity into the next login. Manual
    // logout already releases the device first; this covers the automatic
    // path.
    ref.listen(authProvider, (prev, next) {
      // Every auth transition gets a generation, including a new login after
      // a revocation. Recovery callbacks that were already awaiting a server
      // or storage operation must not be allowed to resurrect a tunnel into a
      // session that is no longer current.
      final previousStatus = prev?.value?.status;
      final nextStatus = next.value?.status;
      // Loading → authenticated is startup hydration, not a session change;
      // counting it would invalidate a cold restore that starts alongside the
      // auth gate. Only an actual authenticated/unauthenticated transition
      // supersedes recovery work.
      if (previousStatus != null &&
          nextStatus != null &&
          previousStatus != nextStatus) {
        _sessionEpoch++;
      }
      final wasAuthed = previousStatus == AuthStatus.authenticated;
      final nowUnauth = nextStatus == AuthStatus.unauthenticated;
      if (!wasAuthed || !nowUnauth) return;
      final sessionEpoch = _sessionEpoch;
      _stopPolling();
      _pollsSinceRotate = 0;
      _resetLocalHealth();
      _coldRestore.clear();
      // Serialize teardown with an in-flight connect/heal/failover. The
      // teardown is queued before any post-login VPN operation, so a later
      // login cannot inherit the revoked device or tunnel.
      unawaited(_teardownRevokedSession(sessionEpoch));
      state = const ConnState(message: 'Session ended. Please log in again.');
    });
    // React to OS link transitions instead of only on the next health tick:
    // a returning link runs the resume catch-up immediately (see
    // [_onLinkChanged]). A platform without a working connectivity channel
    // (or `flutter test`) fails open: the health tick's `hasLink()` still
    // runs, so healing is never blocked by a broken watcher.
    try {
      _linkSub = _networkMonitor.linkChanges.listen(
        _onLinkChanged,
        onError: (Object e) => AppLog.error('network link stream failed', e),
      );
    } catch (e) {
      AppLog.error('network link subscription unavailable (ignoring)', e);
    }
    return const ConnState();
  }
  // ---------------------------------------------------------------------
  // Public API. These stay instance members (never extension methods)
  // because `flutter_riverpod` exposes `ConnectionController` and Dart
  // resolves extension members statically, so a test/preview subclass that
  // `@override`s them would be silently bypassed. Each delegates to the
  // implementation living in its own `conn_*.dart` part file.
  // ---------------------------------------------------------------------

  /// First-launch provisioning. Exactly one optional target (or none).
  Future<void> ensureProvisioned({String? regionId, String? serverId}) =>
      _ensureProvisionedOp(regionId: regionId, serverId: serverId);

  /// Connect: rebuild from `config` when bound, else bind a fresh peer.
  Future<void> connect() => _connectOp();

  /// Quick Connect (Home power button / Regions tile): sticky target,
  /// else the lowest-load region with capacity.
  Future<void> quickConnect() => _quickConnectOp();

  /// Restart the tunnel onto another region/server. [pinTarget] false
  /// dials one-shot without pinning (Auto moves keep the state unpinned).
  Future<void> switchServer({
    required String? regionId,
    required String? serverId,
    bool explicitTarget = true,
    bool pinTarget = true,
  }) => _switchServerOp(
    regionId: regionId,
    serverId: serverId,
    explicitTarget: explicitTarget,
    pinTarget: pinTarget,
  );

  /// Rotate the WireGuard key in place (same server + overlay IP).
  Future<void> rotateKeys({bool auto = false}) => _rotateKeysOp(auto: auto);

  /// One status poll tick (`GET /vpn-devices/{id}/status`).
  Future<void> pollStatusOnce() => _pollStatusOnce();

  /// One local, backend-free health tick.
  Future<void> checkHealthOnce() => _healthCheckOnce();

  /// Foreground-resume catch-up: backend-free health tick, then a status
  /// poll only when the last snapshot is stale.
  Future<void> catchUpOnResume({DateTime? now}) => _catchUpOnResumeOp(now: now);

  /// App hidden/visible switch (driven by [ResumeCoordinator] from the app
  /// lifecycle). No-op for the same value. While connected the running
  /// timers restart on the new cadence; otherwise the flag is picked up when
  /// polling next starts (connect/heal). Foreground is the default, so a
  /// process that never pauses is unaffected.
  void setBackgrounded(bool value) {
    if (_backgrounded == value) return;
    _backgrounded = value;
    if (snap.phase == ConnPhase.connected) _startPolling(earlyStatus: false);
  }

  /// Reconcile app state with a surviving OS tunnel after a cold start or a
  /// reset-to-idle; never restarts it.
  Future<void> reconcileColdStart() => _reconcileColdStartOp();

  /// Persists the split-tunnel preference and restarts a live tunnel.
  /// Returns false when the preference was saved but applying it to a live
  /// tunnel failed.
  Future<bool> setAllowLocal(bool value) => _setAllowLocalOp(value);

  /// Drops local connection state (e.g. after "Forget device").
  void reset() => _resetOp();

  /// Disconnect: graceful tunnel teardown, then release the peer.
  Future<void> disconnect() => _disconnectOp();

  /// Forget-device: disconnect, revoke, then wipe the local identity.
  Future<void> forgetDevice() => _forgetDeviceOp();

  /// Logout release: disconnect, revoke the device server-side (freeing the
  /// plan's `max_devices` slot), then wipe the local identity. Unlike
  /// [forgetDevice] it leaves [snap] untouched — the auth gate owns the
  /// sign-out state.
  Future<void> releaseDevice() => _releaseDeviceOp();

  /// Records the exact pinned target: both sides are always replaced, so
  /// callers must pass the full pair with exactly one side non-null
  /// (the Regions tab passes an explicit null on the unselected side).
  /// [explicitTarget] marks a manual user tap (constrains auto-failover to
  /// the region); null preserves the current flag for internal re-pins
  /// (canonical pins, failover moves). Persisted best-effort so disconnect
  /// → connect and restarts redial the same target; failures only log.
  void selectTarget({
    required String? regionId,
    required String? serverId,
    bool? explicitTarget,
  }) {
    final explicit = explicitTarget ?? state.explicitTarget;
    state = state.copyWith(
      regionId: regionId,
      serverId: serverId,
      explicitTarget: explicit,
    );
    _persistTarget(
      regionId: regionId,
      serverId: serverId,
      explicitTarget: explicit,
    );
  }

  /// Fire-and-forget persist that never throws: the async body catches
  /// both sync throws (e.g. secure storage without a Flutter binding in
  /// tests) and async failures, so callers stay sync and infallible.
  /// [DeviceStore] serializes the write in call order, so this one-liner
  /// cannot land after a later [clearDevice] and resurrect the old target.
  void _persistTarget({
    required String? regionId,
    required String? serverId,
    required bool explicitTarget,
  }) {
    unawaited(() async {
      try {
        await _device.setLastTarget(
          regionId: regionId,
          serverId: serverId,
          explicitTarget: explicitTarget,
        );
      } catch (e) {
        AppLog.error('persist target failed', e);
      }
    }());
  }

  /// Clears any pinned region/server back to Auto (unpinned, non-explicit)
  /// and awaits the persist, so a following [quickConnect] can't resurrect
  /// the old pin from a racing saved-target read. Never throws: storage
  /// failures only log.
  Future<void> selectAuto() async {
    state = state.copyWith(
      regionId: null,
      serverId: null,
      explicitTarget: false,
    );
    try {
      await _device.setLastTarget(
        regionId: null,
        serverId: null,
        explicitTarget: false,
      );
    } catch (e) {
      AppLog.error('select auto persist failed', e);
    }
  }

  /// Pins the canonical target from a freshly loaded [dial] (server truth,
  /// never request params): a server-targeted request pins
  /// `dial.serverId`; a region-targeted request pins the parent region of
  /// `dial.serverId` resolved via discovery, falling back to a server pin
  /// when discovery fails or the server is unknown. Best-effort: never
  /// throws, so a discovery blip can't fail an otherwise good reconnect.
  ///
  /// With [preserveAuto] (the connect-path default) an unpinned (Auto)
  /// state is left alone: Auto reconnects must not collapse into a server
  /// pin. Switch-path callers pass false: an explicit switch carries user
  /// intent even when the pin hasn't landed in [snap] yet (e.g. an
  /// already-bound 409 before the post-success pin).
  Future<void> _pinCanonicalTarget(
    DialParams dial, {
    required bool regionRequest,
    bool preserveAuto = true,
  }) async {
    if (preserveAuto && snap.regionId == null && snap.serverId == null) {
      return;
    }
    if (!regionRequest) {
      selectTarget(regionId: null, serverId: dial.serverId);
      return;
    }
    try {
      final regions = await _api.regions();
      for (final r in regions) {
        if (r.servers.any((s) => s.id == dial.serverId)) {
          selectTarget(regionId: r.id, serverId: null);
          return;
        }
      }
      AppLog.info(
        'canonical pin: server ${dial.serverId} not in discovery -> server pin',
      );
    } catch (e) {
      AppLog.error('canonical pin region resolve failed', e);
    }
    selectTarget(regionId: null, serverId: dial.serverId);
  }

  /// Arms the 429 cooldown from [e] when it is a rate-limit rejection:
  /// `Retry-After` (falling back to the backend's 60s default) plus a 1s
  /// buffer so the next attempt lands after the server window reopens.
  /// Returns the wait when armed, else null.
  Duration? _noteRateLimit(ApiException? e) {
    if (e?.kind != ApiErrorKind.rateLimited) return null;
    final wait =
        (e!.retryAfter ?? const Duration(seconds: 60)) +
        const Duration(seconds: 1);
    _rateLimitedUntil = _clock.now().add(wait);
    AppLog.info('rate limit cooldown armed for ${wait.inSeconds}s');
    return wait;
  }

  /// User-facing countdown for a fresh 429 (see [_noteRateLimit]).
  String _rateLimitMessage(Duration wait) =>
      'Rate limit reached. Please wait ${wait.inSeconds}s.';

  /// True while the cooldown is active: writes a countdown snapshot flagged
  /// [ConnState.opFailed] (so the caller's feedback surface snacks) and
  /// returns true so the caller skips its API call. A live tunnel is kept
  /// `connected`; otherwise the phase falls to `error`.
  bool _blockedByRateLimit(String op) {
    final remaining = _rateLimitRemaining;
    if (remaining == null) return false;
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    AppLog.info('$op skipped (rate limited, ${seconds}s left)');
    snap = snap.copyWith(
      phase: snap.phase == ConnPhase.connected
          ? ConnPhase.connected
          : ConnPhase.error,
      message: 'Rate limit reached. Please wait ${seconds}s.',
      opFailed: true,
    );
    return true;
  }
}

// ---------------------------------------------------------------------------
// Providers the controller depends on. They live here (rather than in
// `vpn_providers.dart`) so this library never has to import it: the discovery
// cache there composes on top of them instead.
// ---------------------------------------------------------------------------

final keyManagerProvider = Provider((_) => KeyManager());
final clockProvider = Provider<Clock>((_) => const SystemClock());
final vpnApiProvider = Provider((ref) {
  final store = ref.watch(sessionStoreProvider);
  return VpnApi(
    buildDio(
      tokenReader: store.apiToken,
      // Refresh hook lives in auth state; read lazily so this provider
      // never subscribes to auth (no rebuild/cycle: auth never reads VPN).
      onUnauthorized: () => ref.read(authProvider.notifier).refreshForRetry(),
    ),
  );
});

/// Split-tunnel preference: true (default) keeps LAN subnets off the
/// tunnel; false is the strict full-tunnel kill switch. Invalidated by
/// [ConnectionController.setAllowLocal] after every change.
final allowLocalProvider = FutureProvider<bool>((ref) async {
  final store = ref.watch(deviceStoreProvider);
  return store.allowLocal();
});

final connectionProvider = NotifierProvider<ConnectionController, ConnState>(
  ConnectionController.new,
);
