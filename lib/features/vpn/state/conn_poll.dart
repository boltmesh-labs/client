part of 'connection_controller.dart';

extension ConnectionPoll on ConnectionController {
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
    final epoch = _tunnelEpoch;
    DeviceStatus st;
    try {
      st = await _api.status(id);
    } on DioException catch (e) {
      if (asVpnError(e)?.kind == ApiErrorKind.notFound) {
        AppLog.info('status 404 -> forget device');
        await _forgetDeviceAndIdle(stopReason: 'status-revoked');
        return;
      }
      // App-level rejections prove the backend is reachable; only
      // transport failures imply a stale/dead path. Auth/app errors
      // (401/403/409/…) return silently — the Dio 401 interceptor
      // already retried once, and revocation is handled via the auth
      // listener.
      final kind = asVpnError(e)?.kind;
      final status = asVpnError(e)?.statusCode;
      if (!isTransportFailure(e)) {
        AppLog.error(
          'status poll app error kind=${kind ?? e.type.name} status=$status',
          e,
        );
        // A reachable-but-unhealthy backend (5xx/429/503) proves the path,
        // so it must not count toward escalation, but the user must not see
        // a perpetual "Connected" while every poll fails: surface a
        // degraded banner the next successful poll clears.
        if ((kind == ApiErrorKind.unknown || kind == ApiErrorKind.noCapacity) &&
            snap.phase == ConnPhase.connected) {
          snap = snap.copyWith(
            healthNote:
                'Backend error${status == null ? '' : ' ($status)'}. '
                'Watching for recovery…',
          );
        }
        return;
      }
      final failures = snap.pollFailures + 1;
      // A poll that was in flight while a heal/refresh/failover stopped
      // the tunnel proves nothing about the backend (its socket died with
      // the teardown): don't count it toward escalation, just note it.
      // The epoch check covers the heal-already-done case too, where the
      // phase is back to `connected` but the socket still died with the
      // previous tunnel generation (errno-10057 `connectionError`).
      if (epoch != _tunnelEpoch) {
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
      snap = snap.copyWith(
        pollFailures: failures,
        healthNote: failures >= ConnectionTuning.degradedPollThreshold
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
      final lapsed = st.suspendedReason == 'subscription_lapsed';
      AppLog.info('status suspended reason=${st.suspendedReason}');
      await _stopTunnel('status-suspended');
      try {
        await _api.disconnect(id);
      } catch (e) {
        AppLog.error('status-suspend disconnect best-effort failed', e);
      }
      _stopPolling();
      _pollsSinceRotate = 0;
      _resetLocalHealth();
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
        ),
      );
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
    if (epoch != _tunnelEpoch) {
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
    snap = snap.copyWith(
      deviceStatus: st,
      lastStatusAt: now,
      pollFailures: 0,
      healthNote: healthyStage ? null : snap.healthNote,
      autoHealAttempts: tunnelHealthy ? 0 : snap.autoHealAttempts,
      autoFailoverAttempts: tunnelHealthy ? 0 : snap.autoFailoverAttempts,
    );
    _pollsSinceRotate++;
    if (_pollsSinceRotate >= Env.keyRotationPolls) {
      await rotateKeys(auto: true);
    }
  }
}
