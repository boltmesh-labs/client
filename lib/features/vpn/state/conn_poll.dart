part of 'connection_controller.dart';

extension ConnectionPoll on ConnectionController {
  /// Runs at most one status tick across timer, resume, and test/manual
  /// callers. The future is returned unchanged so callers still observe the
  /// operation's result; a detached cleanup chain prevents a rejected tick
  /// from becoming an unhandled asynchronous error.
  Future<void> _pollStatusOnce() {
    final active = _statusPollInFlight;
    if (active != null) return active;
    final future = _pollStatusOp();
    _statusPollInFlight = future;
    unawaited(
      future
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (identical(_statusPollInFlight, future)) {
              _statusPollInFlight = null;
            }
          }),
    );
    return future;
  }

  /// One status poll tick: refreshes the session snapshot while connected,
  /// auto-disconnects on `suspended`, and forgets the device on 404
  /// (revoked server-side). Transient transport failures increment
  /// [ConnState.pollFailures] and raise a degraded banner instead of
  /// tearing down a good tunnel. Public so tests can drive a
  /// tick without waiting [Env.statusPollInterval].
  Future<void> _pollStatusOp() async {
    if (snap.phase != ConnPhase.connected) return;
    if (_mutex.isLocked) return;
    final id = await _device.deviceId();
    if (id == null) return;
    // Re-check after the await: a heal/refresh/failover may have taken the
    // mutex and stopped the tunnel underneath this poll. Firing
    // `GET …/status` now would only fail against the teardown (the
    // errno-10057 `connectionError` in the logs) and inflate pollFailures.
    if (snap.phase != ConnPhase.connected || _mutex.isLocked) return;
    final pollDial = snap.dial;
    if (pollDial == null) return;
    final epoch = _tunnelEpoch;
    final sessionEpoch = _sessionEpoch;
    DeviceStatus st;
    try {
      st = await _api.status(id);
    } on DioException catch (e) {
      if (asVpnError(e)?.kind == ApiErrorKind.notFound) {
        // A delayed 404 from an older poll must not clear a newer device or
        // stop a newer tunnel. Serialize the destructive branch and re-check
        // both the device and the dial generation after taking the lock.
        final release = await _mutex.acquire('status-404');
        try {
          if (sessionEpoch != _sessionEpoch ||
              epoch != _tunnelEpoch ||
              snap.phase != ConnPhase.connected ||
              !identical(snap.dial, pollDial)) {
            AppLog.info('status 404 superseded (not forgotten)');
            return;
          }
          final currentId = await _device.deviceId();
          if (currentId != id) {
            AppLog.info('status 404 device superseded (not forgotten)');
            return;
          }
          if (sessionEpoch != _sessionEpoch) return;
          AppLog.info('status 404 -> forget device');
          await _forgetDeviceAndIdle(stopReason: 'status-revoked');
        } finally {
          release();
        }
        return;
      }
      // App-level rejections prove the backend is reachable; only
      // transport failures imply a stale/dead path. A reachable backend that
      // rejects us (401/403) or is unhealthy (5xx/429) is not a network
      // outage, so record the distinct [BackendIssue] for diagnostics. The
      // banner copy for auth/subscription comes from that issue (no
      // healthNote is set for those); 5xx/429 keep their existing degraded
      // note.
      final kind = asVpnError(e)?.kind;
      final status = asVpnError(e)?.statusCode;
      if (!isTransportFailure(e)) {
        AppLog.error(
          'status poll app error kind=${kind ?? e.type.name} status=$status',
          e,
        );
        // A response — including 401/403/429/5xx — proves that the control
        // plane answered. Do not let an old transport-failure count or the
        // quiet-track timer turn that answered state into a heal trigger.
        if (sessionEpoch != _sessionEpoch ||
            epoch != _tunnelEpoch ||
            snap.phase != ConnPhase.connected ||
            !identical(snap.dial, pollDial)) {
          AppLog.info('status app error superseded (not recorded)');
          return;
        }
        final vpnErr = asVpnError(e);
        _noteRateLimit(vpnErr);
        final issue = classifyBackendIssue(vpnErr);
        final degraded =
            kind == ApiErrorKind.unknown ||
            kind == ApiErrorKind.noCapacity ||
            kind == ApiErrorKind.rateLimited;
        final authIssue =
            issue == BackendIssue.authExpired ||
            issue == BackendIssue.subscriptionInactive;
        final String? note;
        if (degraded) {
          note =
              'Backend error${status == null ? '' : ' ($status)'}. '
              'Watching for recovery…';
        } else if (authIssue) {
          note = null;
        } else {
          note = snap.healthNote;
        }
        _lastStatusAnswered = true;
        snap = snap.copyWith(
          pollFailures: 0,
          backendIssue: issue,
          healthNote: note,
        );
        return;
      }
      final failures = snap.pollFailures + 1;
      // A poll that was in flight while a heal/refresh/failover stopped
      // the tunnel proves nothing about the backend (its socket died with
      // the teardown): don't count it toward escalation, just note it.
      // The epoch check covers the heal-already-done case too, where the
      // phase is back to `connected` but the socket still died with the
      // previous tunnel generation (errno-10057 `connectionError`).
      if (sessionEpoch != _sessionEpoch || epoch != _tunnelEpoch) {
        AppLog.info('status poll superseded by tunnel-restart (not counted)');
        return;
      }
      if (snap.phase != ConnPhase.connected) {
        AppLog.info(
          'status poll superseded by ${snap.phase.name} (not counted)',
        );
        return;
      }
      AppLog.error('status poll transient ($failures)', e);
      final degraded = failures >= ConnectionTuning.degradedPollThreshold;
      _lastStatusAnswered = false;
      snap = snap.copyWith(
        pollFailures: failures,
        // A later transport failure supersedes an answered 5xx/429 issue;
        // auth/subscription issues remain authoritative until the auth layer
        // changes state.
        backendIssue: degraded
            ? BackendIssue.unreachable
            : snap.backendIssue == BackendIssue.serverError
            ? null
            : snap.backendIssue,
        healthNote: degraded
            ? 'Backend unreachable ($failures×). Tunnel may be stale — '
                  'it stays up while recovery is attempted.'
            : snap.healthNote,
      );
      return;
    } catch (e) {
      AppLog.error('status poll failed', e);
      return;
    }
    // Started before a tunnel restart: the snapshot belongs to the old
    // generation, so it must neither clear outage evidence nor refresh
    // the quiet-track clock.
    if (epoch != _tunnelEpoch) {
      AppLog.info('status poll superseded by tunnel-restart (not counted)');
      return;
    }
    final now = _clock.now();
    if (st.isSuspended) {
      // Suspension is a terminal response, not a passive snapshot. Serialize
      // it with connect/switch/heal and re-check the generation so a delayed
      // response cannot release a newer device or tear down a replacement
      // tunnel.
      final release = await _mutex.acquire('status-suspended');
      try {
        if (sessionEpoch != _sessionEpoch ||
            epoch != _tunnelEpoch ||
            snap.phase != ConnPhase.connected ||
            !identical(snap.dial, pollDial)) {
          AppLog.info('status suspension superseded (not applied)');
          return;
        }
        final lapsed = st.suspendedReason == 'subscription_lapsed';
        AppLog.info('status suspended reason=${st.suspendedReason}');
        await _stopTunnel('status-suspended');
        try {
          await _api.disconnect(id);
        } catch (e) {
          AppLog.error('status-suspend disconnect best-effort failed', e);
        }
        if (sessionEpoch != _sessionEpoch) return;
        _stopPolling();
        _pollsSinceRotate = 0;
        _resetLocalHealth();
        // The device is kept so the user can renew, but its peer is gone:
        // drop the cached dial so an offline cold start can't optimistically
        // restore (or sit verifying) the suspended session.
        await _clearCachedDial();
        snap = _resetSessionCounters(
          snap.copyWith(
            phase: ConnPhase.idle,
            deviceStatus: st,
            lastStatusAt: now,
            message: lapsed
                ? 'Subscription lapsed. Renew to reconnect.'
                : 'Device suspended (${st.suspendedReason ?? 'disabled'}).',
            lastStage: null,
            healthNote: null,
            backendIssue: null,
          ),
        );
      } finally {
        release();
      }
      return;
    }
    // Backend reachable again: clear the failure count and any
    // backend-driven banner (a stage-driven note persists via lastStage).
    // A reachable backend ends the outage window and restores every
    // per-outage budget (heal, failover) — but only when the *tunnel* is
    // actually healthy. A poll can succeed out-of-band while the WireGuard
    // path is dead (WG UDP blocked, API reachable): resetting the budgets
    // then would let the ladder loop forever. Require an observed, fresh
    // handshake; an unsupported reader (no handshake telemetry) keeps the
    // old reset-on-poll behavior.
    final hs = await _readHandshake();
    // The read above is an await: drop a snapshot a heal/failover just
    // superseded (same reason as the pre-status epoch check).
    if (sessionEpoch != _sessionEpoch ||
        epoch != _tunnelEpoch ||
        snap.phase != ConnPhase.connected ||
        !identical(snap.dial, pollDial)) {
      AppLog.info('status poll superseded by tunnel-restart (not counted)');
      return;
    }
    final tunnelHealthy =
        !_readerSupported ||
        (hs != null &&
            now.difference(hs) < ConnectionTuning.handshakeStaleAfter);
    final healthyStage =
        snap.lastStage == null || snap.lastStage == VpnStage.connected;
    // A status poll that succeeded through the live tunnel proves the data
    // path reachable, so any dead-echo run is stale evidence: clear it.
    _deadEchoStrikes = 0;
    _lastStatusAnswered = false;
    snap = snap.copyWith(
      deviceStatus: st,
      lastStatusAt: now,
      pollFailures: 0,
      healthNote: healthyStage ? null : snap.healthNote,
      backendIssue: null,
      autoHealAttempts: tunnelHealthy ? 0 : snap.autoHealAttempts,
      autoFailoverAttempts: tunnelHealthy ? 0 : snap.autoFailoverAttempts,
    );
    _pollsSinceRotate++;
    if (_pollsSinceRotate >= Env.keyRotationPolls &&
        snap.phase == ConnPhase.connected &&
        identical(snap.dial, pollDial)) {
      await rotateKeys(auto: true);
    }
  }
}
