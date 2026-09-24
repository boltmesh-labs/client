part of 'connection_controller.dart';

/// Banner while a `disconnected` stage is being corroborated (see
/// [_noteStage]). Only this exact value is cleared on adopt, so a
/// concurrent backend-driven banner is never wiped.
const _externalStopVerifyingNote = 'Verifying VPN status…';

/// Stages that mean the native tunnel is leaving or has left the up state.
/// These need the same corroboration as [VpnStage.disconnected]; treating
/// them as merely informational can strand a connected session when the
/// final terminal event is lost.
bool _isExternalStopStage(VpnStage stage) =>
    stage == VpnStage.disconnected ||
    stage == VpnStage.disconnecting ||
    stage == VpnStage.exiting;

/// Remediation for a `denied` stage is platform-specific: Windows emits it
/// when the privileged `boltmeshd` helper service is missing or stopped (the
/// app itself is unprivileged), while Android/iOS emit it when the VPN
/// consent grant is missing.
String _deniedMessage() => defaultTargetPlatform == TargetPlatform.windows
    ? 'VPN tunnel could not start. Make sure the BoltMesh helper service is '
          'installed and running, then reconnect.'
    : 'VPN permission denied. Re-allow it in system settings.';

extension ConnectionStage on ConnectionController {
  void _noteStage(VpnStage stage) {
    // Cold-restore watch (see [reconcileColdStart]): the confirm couldn't
    // run or failed while the OS tunnel was up. A later `connected` event
    // retries it; a terminal event falls back to idle instead of stranding
    // the optimistic/working state. Scoped to idle/working (never a live
    // session) so normal sessions never enter here.
    if (_coldRestore.armed &&
        (snap.phase == ConnPhase.idle || snap.phase == ConnPhase.working)) {
      if (stage == VpnStage.connected) {
        _coldRestore.armed = false;
        // A down-read restore parks in `working` with the cached dial set
        // while server truth is unreachable (see [_restoreColdSession]);
        // drop it so reconcileColdStart's dial guard doesn't no-op the
        // retry (the confirm re-reads the cache).
        if (snap.dial != null) snap = snap.copyWith(dial: null);
        unawaited(
          reconcileColdStart().catchError(
            (Object e) => AppLog.error('cold restore event failed', e),
          ),
        );
        return;
      }
      if (stage == VpnStage.disconnected ||
          stage == VpnStage.disconnecting ||
          stage == VpnStage.exiting ||
          stage == VpnStage.denied) {
        _coldRestore.armed = false;
        _stopPolling();
        _resetLocalHealth();
        snap = _resetSessionCounters(
          snap.copyWith(
            phase: ConnPhase.idle,
            message: 'VPN stopped. Tap Connect to reconnect.',
            lastStage: stage,
            healthNote: null,
            backendIssue: null,
          ),
        );
        return;
      }
    }
    if (snap.phase != ConnPhase.connected) {
      snap = snap.copyWith(lastStage: stage);
      return;
    }
    if (_isExternalStopStage(stage)) {
      // A fresh engine re-attach reports no running tunnels even when the
      // OS TUN survived, and the stage stream replays that lie right after
      // a server-truth-confirmed cold restore. Honoring it here would flip
      // the just-restored session to idle and orphan the live native
      // tunnel (which then handshakes into the void once its peer is
      // gone). Ignore it inside the grace window; otherwise server truth
      // decides via [_corroborateExternalStop] below.
      if (_coldRestore.inGrace(_clock.now())) {
        AppLog.info('cold grace: ignoring stale disconnected stage');
        return;
      }
      // A confirm (or any op) holding the mutex reconciles state itself;
      // recording the stage is enough — acting here would race it and
      // orphan the just-restored session.
      if (_mutex.isLocked) {
        AppLog.info('tunnel stage=${stage.name} during op -> defer to holder');
        snap = snap.copyWith(lastStage: stage);
        return;
      }
      if (snap.dial == null) {
        snap = snap.copyWith(lastStage: stage);
        return;
      }
      // A lone `disconnected` is untrustworthy (fresh-backend lie) and racy
      // in general, so it never tears down directly. Stay connected with a
      // verifying banner and corroborate async: only a corroborated-dead
      // tunnel flips to idle and ghost-kills. A false adopt self-corrects
      // via health ticks/status polls; a false kill strands the user.
      final sessionEpoch = _sessionEpoch;
      AppLog.info('tunnel stage=${stage.name} -> verifying');
      snap = snap.copyWith(
        lastStage: stage,
        healthNote: _externalStopVerifyingNote,
      );
      unawaited(
        _corroborateExternalStop(
          _tunnelEpoch,
          snap.dial,
          sessionEpoch: sessionEpoch,
        ),
      );
      return;
    }
    if (stage == VpnStage.denied) {
      if (_coldRestore.inGrace(_clock.now())) {
        AppLog.info('cold grace: ignoring stale denied stage');
        return;
      }
      _coldRestore.confirmedAt = null;
      AppLog.info('tunnel stage=denied -> error');
      _stopPolling();
      _resetLocalHealth();
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: _deniedMessage(),
        lastStage: stage,
        autoHealAttempts: 0,
        autoFailoverAttempts: 0,
      );
      return;
    }
    if (_isDegradedStage(stage)) {
      AppLog.info('tunnel stage=${stage.name} -> degraded');
      // Only a *transition* into the degraded stage kicks: a broadcast that
      // repeats the same stage must not fire a probe run every emit (the
      // periodic tick still covers a stall that persists).
      final entering = snap.lastStage != stage;
      snap = snap.copyWith(
        lastStage: stage,
        healthNote: 'VPN network issue (${stage.name}). Watching for recovery…',
      );
      // The OS just confirmed the data path is unhealthy: kick a health tick
      // now instead of waiting out the 10s cadence, so the stall is
      // corroborated (or cleared by a live echo) on the first tick. Coalesced
      // through the polling service, and a no-op when no tick is running.
      if (entering) _polling.kickHealth();
      return;
    }
    // Healthy stage: record it; clear a stage-driven note once the tunnel
    // reports connected again (a backend-driven note is cleared by the
    // next successful status poll instead).
    if (snap.pollFailures == 0) {
      snap = snap.copyWith(lastStage: stage, healthNote: null);
    } else {
      snap = snap.copyWith(lastStage: stage);
    }
  }

  /// Verifies a `disconnected` stage observed while connected. Server truth
  /// decides: `GET …/config` proving the peer alive adopts the session,
  /// `notFound`/`noActivePeer` tears it down, and anything in between falls
  /// back to local liveness (re-read stage, handshake freshness, in-tunnel
  /// gateway echo). Unknown evidence defers: a null handshake with a dead or
  /// skipped gateway probe keeps the verifying banner and lets the health
  /// ticks / status polls keep corroborating, instead of adopting a
  /// possibly-dead tunnel as Connected. Never throws; act-time
  /// epoch/dial guards make overlapping runs idempotent.
  Future<void> _corroborateExternalStop(
    int epoch,
    DialParams? dial, {
    required int sessionEpoch,
  }) async {
    try {
      if (dial == null) return;
      if (sessionEpoch != _sessionEpoch || _tunnelEpoch != epoch) return;
      if (snap.phase != ConnPhase.connected || !identical(snap.dial, dial)) {
        return;
      }
      // 1. Server truth: an explicit dead peer tears down, an unreachable
      // backend defers (health/status machinery owns it from here).
      try {
        await _api.config(dial.deviceId);
      } on DioException catch (e) {
        final kind = asVpnError(e)?.kind;
        if (kind == ApiErrorKind.notFound ||
            kind == ApiErrorKind.noActivePeer) {
          AppLog.info('external-stop corroborated dead ($kind) -> idle');
          await _tearDownCorroboratedDead(
            epoch,
            dial,
            kind: kind,
            sessionEpoch: sessionEpoch,
          );
          return;
        }
        AppLog.info('external-stop verify deferred (config unreachable)');
        return;
      } catch (e) {
        AppLog.error('external-stop verify failed', e);
        return;
      }
      if (sessionEpoch != _sessionEpoch ||
          _tunnelEpoch != epoch ||
          snap.phase != ConnPhase.connected ||
          !identical(snap.dial, dial)) {
        AppLog.info('external-stop verify superseded -> skip');
        return;
      }
      // 2. Local liveness: any sign of life adopts (fresh-backend lie).
      final restage = await _tunnel.readStage();
      if (restage != null &&
          (restage == VpnStage.connected ||
              _isDegradedStage(restage) ||
              isColdTransitionalStage(restage))) {
        _adoptExternalStop(
          epoch,
          dial,
          'stage=${restage.name}',
          restage,
          sessionEpoch: sessionEpoch,
        );
        return;
      }
      final now = _clock.now();
      final handshake = await _readHandshake();
      final stale = isHandshakeStale(
        lastHandshakeAt: handshake,
        now: now,
        connectedAt: _connectedAt,
        // Verification keeps the full null window: it only runs with OS
        // stage evidence in hand, so there is no reason to shorten the
        // 150s aging (the 45s never-handshook grace is a connected-stage
        // concern; see [ConnectionHealth]).
        graceAfter: ConnectionTuning.handshakeStaleAfter,
      );
      // Tri-state, never throws (see [ConnectionHealth._gatewayAlive]):
      // null = skipped/errored (unknown, defers), false = echoed-dead.
      final gateway = await _gatewayAlive(dial.wgDns);
      if (gateway == true) {
        _adoptExternalStop(
          epoch,
          dial,
          'gateway alive',
          null,
          sessionEpoch: sessionEpoch,
        );
        return;
      }
      if (!stale) {
        // A fresh handshake timestamp is positive liveness: adopt. An
        // unknown read (null, e.g. the native reader missing on this
        // platform) proves nothing — defer so the health ticks keep
        // corroborating instead of locking in a possibly-dead Connected.
        if (handshake != null) {
          _adoptExternalStop(
            epoch,
            dial,
            'handshake fresh',
            null,
            sessionEpoch: sessionEpoch,
          );
          return;
        }
        AppLog.info(
          'external-stop verify deferred '
          '(handshake unknown, gateway ${gateway == null ? 'skipped' : 'dead'})',
        );
        return;
      }
      // 3. All dead: stage still terminal, handshake stale-confirmed,
      // gateway dead, backend answered — a true outside kill, not the lie.
      AppLog.info(
        'external-stop corroborated dead '
        '(stage down, handshake stale, gateway dead) -> idle',
      );
      await _tearDownCorroboratedDead(
        epoch,
        dial,
        kind: null,
        sessionEpoch: sessionEpoch,
      );
    } catch (e) {
      AppLog.error('external-stop corroboration failed', e);
    }
  }

  /// Adopts the session after an uncorroborated `disconnected` stage: stays
  /// connected, clears only our own verifying banner. A corroborating
  /// non-terminal re-read also refreshes the recorded stage.
  void _adoptExternalStop(
    int epoch,
    DialParams dial,
    String why,
    VpnStage? restage, {
    required int sessionEpoch,
  }) {
    if (sessionEpoch != _sessionEpoch ||
        _tunnelEpoch != epoch ||
        snap.phase != ConnPhase.connected ||
        !identical(snap.dial, dial)) {
      return;
    }
    AppLog.info('external-stop uncorroborated ($why) -> adopted');
    snap = snap.copyWith(
      lastStage: restage ?? snap.lastStage,
      healthNote: snap.healthNote == _externalStopVerifyingNote
          ? null
          : snap.healthNote,
    );
  }

  /// True right after a down-stage cold restore confirmed by server truth:
  /// [_connectedAt] was just anchored while working, so an unknown (null)
  /// handshake read looks "fresh" even though the tunnel may have been dead
  /// for hours. The native handshake reader is also unimplemented on some
  /// platforms (see `client/android/.../MainActivity.kt`), where null is the
  /// only possible read. Callers must defer on unknown evidence while this
  /// holds instead of adopting (see [_restoreColdSession]). A real (non-null)
  /// timestamp is unaffected: only null reads are ambiguous.
  bool _unknownHandshakeIsColdAnchored(DateTime now) {
    final confirmedAt = _coldRestore.confirmedAt;
    final anchoredAt = _connectedAt;
    if (confirmedAt == null || anchoredAt == null) return false;
    if (now.difference(anchoredAt) >= ConnectionTuning.handshakeStaleAfter) {
      return false;
    }
    return now.difference(confirmedAt) < ConnectionTuning.handshakeStaleAfter;
  }

  /// Tears down a corroborated-dead outside stop: idle (the server peer is
  /// preserved for one-tap reconnect, except on `notFound` where the device
  /// itself is gone) plus a guarded ghost-kill for the handle-less native
  /// tunnel. No-op when superseded.
  ///
  /// Serialized under [_mutex]: an unguarded teardown could overlap a Connect
  /// that started while its stop was blocked (killing the fresh tunnel and
  /// wedging the Windows/Wintun route), and a stale `notFound` could wipe the
  /// identity a concurrent Connect had just created. Waiters queue FIFO, so a
  /// Connect queued behind this teardown starts only after the OS tunnel is
  /// fully down; one that already ran bumps [_tunnelEpoch] (stop) or replaces
  /// the dial, and the re-check below skips the stale teardown.
  Future<void> _tearDownCorroboratedDead(
    int epoch,
    DialParams dial, {
    required ApiErrorKind? kind,
    required int sessionEpoch,
  }) async {
    final release = await _mutex.acquire('external-stop');
    try {
      if (sessionEpoch != _sessionEpoch ||
          _tunnelEpoch != epoch ||
          snap.phase != ConnPhase.connected ||
          !identical(snap.dial, dial)) {
        AppLog.info('corroborated teardown superseded -> skip');
        return;
      }
      _coldRestore.confirmedAt = null;
      _stopPolling();
      _resetLocalHealth();
      if (kind == ApiErrorKind.notFound) {
        try {
          await _wipeDevice();
        } catch (e) {
          AppLog.error('external-stop clear device failed', e);
        }
      } else if (kind == ApiErrorKind.noActivePeer) {
        // Device kept for a fresh bind, but the cached dial points at the
        // peer the server just reported gone: drop it so a later offline
        // cold start can't restore the dead session.
        await _clearCachedDial();
      }
      _idleAfterDeviceGone(
        message: kind == ApiErrorKind.notFound
            ? 'Device was removed. Connect again to reprovision.'
            : kind == ApiErrorKind.noActivePeer
            ? 'Session expired. Tap Connect to reconnect.'
            : 'VPN stopped outside the app',
        lastStage: VpnStage.disconnected,
        keepDial: kind == null,
      );
      // The native tunnel still needs killing: after a re-attach the plugin
      // lost its handle, so a plain stop is a no-op (`Running tunnels: []`)
      // and the OS tunnel keeps handshaking. The ghost-kill downs the owning
      // backend directly (same object identity). Awaited under the lock so a
      // queued Connect cannot start a replacement until this is down.
      await _stopTunnel('external-stop');
    } finally {
      release();
    }
  }
}
