part of 'connection_controller.dart';

/// Message for every device-gone (404/revoked) teardown path.
const _deviceGoneMessage = 'Device was removed. Connect again to reprovision.';

extension ConnectionLifecycle on ConnectionController {
  /// Copy of [s] with every per-session recovery counter and the
  /// poll-failure evidence cleared. Applied when a session ends (idle/error
  /// teardown) or a fresh one is promoted, so the next connect/outage starts
  /// from a clean budget.
  ConnState _resetSessionCounters(ConnState s) =>
      s.copyWith(pollFailures: 0, autoHealAttempts: 0, autoFailoverAttempts: 0);

  /// Tears down a tunnel after an involuntary auth/session transition.
  ///
  /// The auth listener is synchronous, so the actual privileged/storage work
  /// is queued behind the same mutex as connect/heal/switch. The teardown is
  /// deliberately not canceled by a later auth generation: the queued cleanup
  /// owns the revoked session's physical tunnel and device identity, and runs
  /// before any post-login VPN operation that can be queued after it.
  Future<void> _teardownRevokedSession(int sessionEpoch) async {
    final release = await _mutex.acquire('session-revoked');
    try {
      // An in-flight lock-free discovery/probe belonging to the revoked
      // session must not dial once this queued teardown has run.
      _teardownEpoch++;
      if (sessionEpoch != _sessionEpoch) {
        // A new login may already have changed the auth generation, but the
        // physical tunnel and device identity still belong to the revoked
        // session. The teardown was queued before any post-login VPN op, so
        // finish the cleanup unconditionally rather than leaking that state.
        AppLog.info('session-revoked cleanup superseded auth generation');
      }
      try {
        await _stopTunnel('session-revoked');
      } catch (e) {
        AppLog.error('session-revoked stop failed', e);
      }
      try {
        await _device.clearDevice();
      } catch (e) {
        AppLog.error('session-revoked clear device failed', e);
      }
      // An operation that was already inside _startWith may have published a
      // connected/working snapshot after the listener reset the state. Make
      // the terminal state authoritative after the serialized cleanup.
      snap = const ConnState(message: 'Session ended. Please log in again.');
    } finally {
      release();
    }
  }

  /// Drops local connection state (e.g. after "Forget device").
  /// Callers must not hold [_mutex] here: reset runs after the owning op
  /// (e.g. `disconnect`) has released it.
  void _resetOp() {
    _stopPolling();
    _pollsSinceRotate = 0;
    _resetLocalHealth();
    _coldRestore.clear();
    // Supersede any lock-free discovery/probe still in flight.
    _teardownEpoch++;
    snap = const ConnState(message: 'Ready');
  }

  /// Resets [snap] to a device-gone idle state: clears any session identity
  /// (dial unless [keepDial]) and every per-session counter/health signal.
  /// Shared by the 404/peerless paths (status poll, failover, refresh, cold
  /// restore) and the external-stop teardown. [lastStage] records a specific
  /// observed stage when the caller has one; [keepDial] preserves the dial for
  /// a one-tap reconnect (external-stop's non-notFound branch).
  void _idleAfterDeviceGone({
    required String message,
    VpnStage? lastStage,
    bool keepDial = false,
  }) {
    snap = _resetSessionCounters(
      snap.copyWith(
        phase: ConnPhase.idle,
        dial: keepDial ? snap.dial : null,
        deviceStatus: null,
        lastStatusAt: null,
        message: message,
        lastStage: lastStage,
        healthNote: null,
        backendIssue: null,
      ),
    );
  }

  /// Re-asserts a healthy connected snapshot: keeps the live tunnel and
  /// clears any backend-driven banner after a probe/fetch proved the backend
  /// reachable (the next health tick retries whatever failed).
  void _keepConnected() {
    snap = snap.copyWith(
      phase: ConnPhase.connected,
      message: 'Connected',
      healthNote: null,
      backendIssue: null,
    );
  }

  /// Ends a disconnect in the local-only state: the tunnel is already down
  /// and the server-side peer release is deferred. Shared by the API-failure
  /// and 429-skip paths so both leave the same usable idle snapshot.
  void _finishLocalDisconnect(String message) {
    _stopPolling();
    _pollsSinceRotate = 0;
    _resetLocalHealth();
    snap = _resetSessionCounters(
      snap.copyWith(
        phase: ConnPhase.idle,
        deviceStatus: null,
        lastStatusAt: null,
        message: message,
        lastStage: null,
        healthNote: null,
        backendIssue: null,
      ),
    );
  }

  /// Device-gone (404/revoked) teardown shared by the status-poll, heal and
  /// failover paths: stop the tunnel ([stopReason] null when the caller
  /// already did), wipe the local identity, and drop to idle with [message].
  Future<void> _forgetDeviceAndIdle({
    String message = _deviceGoneMessage,
    String? stopReason,
  }) async {
    if (stopReason != null) await _stopTunnel(stopReason);
    try {
      await _device.clearDevice();
    } catch (e) {
      // The tunnel is already down; leave a recoverable idle snapshot even if
      // secure storage is temporarily unavailable.
      AppLog.error('forget device clear failed', e);
    }
    _stopPolling();
    _pollsSinceRotate = 0;
    _resetLocalHealth();
    _idleAfterDeviceGone(message: message);
  }

  /// Persists the split-tunnel preference and, when connected, restarts the
  /// tunnel on the cached dial params so the new AllowedIPs take effect at
  /// once. The restart is offline (no API call), mirroring [_autoHeal]. When
  /// idle/error the preference simply applies to the next connect.
  Future<void> _setAllowLocalOp(bool value) async {
    await _device.setAllowLocal(value);
    _invalidateAllowLocal();
    if (snap.phase != ConnPhase.connected || snap.dial == null) return;
    final release = await _mutex.acquire('lan-toggle');
    final sessionEpoch = _sessionEpoch;
    try {
      final dial = snap.dial;
      if (snap.phase != ConnPhase.connected || dial == null) return;
      AppLog.info('lan-toggle restart allowLocal=$value');
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Applying network setting…',
      );
      // Explicit stop first: [_startWith] only stops a `connected` tunnel,
      // and the phase above is already `working` (same pattern as
      // [_autoHeal]). Never run two live tunnels (Windows/Wintun wedge).
      await _stopTunnel('lan-toggle');
      if (sessionEpoch != _sessionEpoch) return;
      await _startWith(dial, sessionEpoch: sessionEpoch);
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error('lan-toggle restart failed', vpnErr?.message ?? e);
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: vpnErr?.message ?? e.toString(),
      );
    } finally {
      release();
    }
  }

  /// First-launch provisioning. Exactly one optional target (or none).
  Future<void> _ensureProvisionedOp({
    String? regionId,
    String? serverId,
  }) async {
    final release = await _mutex.acquire('provision');
    final sessionEpoch = _sessionEpoch;
    try {
      await _provision(
        regionId: regionId,
        serverId: serverId,
        sessionEpoch: sessionEpoch,
      );
    } finally {
      release();
    }
  }

  /// Disconnect: graceful tunnel teardown, then release the peer
  /// server-side (idempotent; works with a lapsed subscription).
  ///
  /// The tunnel stop is authoritative (see [TunnelAdapter.stop]), so
  /// disconnect never strands the user. A dead control plane still ends in
  /// `idle` with a "pending release" note instead of trapping the user in
  /// `error`. Queued behind any running op instead of being dropped.
  Future<void> _disconnectOp() async {
    final release = await _mutex.acquire('disconnect');
    try {
      await _disconnectBody();
    } finally {
      release();
    }
  }

  /// Lock-free disconnect implementation. The caller must hold [_mutex];
  /// shared by [disconnect] and [_releaseDeviceOp] so the teardown, revoke
  /// and local wipe run under one lock and a concurrent Connect can never
  /// interleave to bind a device that [_device.clearDevice] then wipes.
  Future<void> _disconnectBody() async {
    // Bump before the first await so a lock-free Quick Connect discovery
    // that already ran can never bind/dial after this explicit teardown.
    _teardownEpoch++;
    try {
      // The tunnel stop is authoritative and never throws: run it first so
      // a secure-storage read failure can never leave the tunnel up while
      // the UI reports `error`.
      snap = snap.copyWith(phase: ConnPhase.working, message: 'Disconnecting…');
      await _stopTunnel('disconnect');
      // The tunnel is down: the cached dial must never resurrect it, and
      // any pending cold watch is superseded by this explicit teardown.
      _coldRestore.clear();
      try {
        await _device.clearLastDial();
      } catch (e) {
        AppLog.error('disconnect clear dial failed', e);
      }
      String? id;
      try {
        id = await _device.deviceId();
      } catch (e) {
        AppLog.error('disconnect device read failed', e);
        id = null;
      }
      AppLog.info('disconnect start device=${AppLog.redact(id)}');
      if (id != null) {
        // Skip the peer-release POST while a 429 cooldown is active: the
        // local teardown above is authoritative, and a rejected POST would
        // only spend more of the shared budget (and risk stalling the UI).
        final rateWait = _rateLimitRemaining;
        if (rateWait != null) {
          final seconds = (rateWait.inMilliseconds / 1000).ceil();
          AppLog.info(
            'disconnect api skipped (rate limited, ${seconds}s left)',
          );
          _finishLocalDisconnect(
            'Disconnected locally. Server release pending '
            '(rate limited, ${seconds}s).',
          );
          return;
        }
        try {
          await _api.disconnect(id);
        } on DioException catch (e) {
          final kind = asVpnError(e)?.kind;
          final reason = asVpnError(e)?.message ?? e.toString();
          AppLog.error('disconnect api failed kind=$kind', e);
          _noteRateLimit(asVpnError(e));
          // Tunnel is down either way: stay usable, flag the pending
          // server-side release (cleared on the next connect).
          _finishLocalDisconnect(
            kind == ApiErrorKind.notFound
                ? 'Disconnected'
                : 'Disconnected locally. Server release pending ($reason)',
          );
          AppLog.info('disconnect ok device=${AppLog.redact(id)} (local)');
          return;
        }
      }
      AppLog.info('disconnect ok device=${AppLog.redact(id)}');
      _finishLocalDisconnect('Disconnected');
    } catch (e) {
      final vpnErr = asVpnError(e);
      AppLog.error(
        'disconnect failed kind=${vpnErr?.kind ?? e.runtimeType}',
        vpnErr?.message ?? e,
      );
      // The tunnel was already stopped above: never leave a stale stage
      // next to the error.
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: vpnErr?.message ?? e.toString(),
        lastStage: null,
      );
    }
  }

  /// Forget-device: releases the server-side device (disconnect + revoke),
  /// wipes the local identity, then resets the UI.
  Future<void> _forgetDeviceOp() async {
    await _releaseDeviceOp();
    reset();
  }

  /// Server-side device release + local wipe shared by [forgetDevice] and
  /// logout: graceful `disconnect` (tunnel down + peer release), then a hard
  /// `revoke` (frees the `max_devices` slot), then the local identity wipe.
  ///
  /// Revoke is what makes re-login safe: [disconnect] keeps the device row,
  /// which keeps counting toward the plan's device limit — so a logout that
  /// only disconnected would burn a fresh slot on every re-login.
  ///
  /// Revoke 404 means already revoked — treated as success. Any other revoke
  /// failure is logged but never blocks the local wipe: the tunnel is already
  /// down and the UI must not trap the user.
  Future<void> _releaseDeviceOp() async {
    // One lock for the whole release: the teardown, revoke and local wipe
    // must not be split by a concurrent Connect, which could otherwise bind
    // a fresh device that the wipe then destroys. [_disconnectBody] is
    // lock-free so the mutex can be held across the teardown too.
    final release = await _mutex.acquire('release-device');
    try {
      String? id;
      try {
        id = await _device.deviceId();
      } catch (e) {
        AppLog.error('release device read failed', e);
        id = null;
      }
      await _disconnectBody();
      if (id != null) {
        try {
          await _api.revoke(id);
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            AppLog.info(
              'release revoke already gone device=${AppLog.redact(id)}',
            );
          } else {
            AppLog.error('release revoke failed', e);
          }
        } catch (e) {
          AppLog.error('release revoke failed', e);
        }
      }
      await _device.clearDevice();
    } finally {
      release();
    }
  }
}
