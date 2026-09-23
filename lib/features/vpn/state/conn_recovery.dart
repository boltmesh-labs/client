part of 'connection_controller.dart';

/// Heal/failover escalation ladder for the connected tunnel.
///
/// A corroborated stall restarts the cached config offline ([_autoHeal]);
/// a stall that survives that escalates straight to moving servers
/// ([_autoFailover]) — there is no same-server config refresh in between.
extension ConnectionRecovery on ConnectionController {
  /// Offline restart on the cached config: zero API calls, so it works
  /// with no network or a dead control plane. Retries on every corroborated
  /// stall while connected — capped once the move budget is spent (see
  /// [ConnectionTuning.maxHealsAfterMoveBudget] and
  /// [_surfaceRecoveryExhausted]); the health-tick cadence is the backoff.
  /// Never runs for auth/subscription failures: those leave `connected` via
  /// `pollStatusOnce`/the session listener, and the guards below return
  /// early outside `connected`.
  ///
  /// [hardStalled] (the handshake stayed dead past
  /// [ConnectionTuning.hardHandshakeStaleAfter]) bypasses the
  /// "backend reachable" suppression below: a reachable out-of-band control
  /// plane no longer proves the data path when the handshake is hard-dead.
  Future<void> _autoHeal(
    String why, {
    bool hardStalled = false,
    int? expectedSession,
    int? expectedEpoch,
    DialParams? expectedDial,
  }) async {
    final release = await _mutex.acquire('auto-heal');
    try {
      if (expectedSession != null && expectedSession != _sessionEpoch) return;
      if (expectedEpoch != null && expectedEpoch != _tunnelEpoch) return;
      if (expectedDial != null && !identical(snap.dial, expectedDial)) {
        return;
      }
      final dial = snap.dial;
      if (dial == null || snap.phase != ConnPhase.connected) return;
      if (!hardStalled && _lastStatusAnswered) return;
      final sessionEpoch = _sessionEpoch;
      final attempt = snap.autoHealAttempts + 1;
      // [_startWith] resets the failover budget; a same-server restart must
      // not consume or clear it. Poll failures are outage evidence, not
      // per-restart state: wiping them forces two fresh 60s polls after
      // every heal before the stall can escalate.
      final prevFailovers = snap.autoFailoverAttempts;
      final prevPollFailures = snap.pollFailures;
      AppLog.info('auto-heal start ($why) attempt=$attempt ${_healBudgets()}');
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Reconnecting…',
        autoHealAttempts: attempt,
        healthNote: 'VPN stalled ($why). Reconnecting…',
      );
      // A status poll may have proven the backend reachable after the tick
      // scheduled this heal: stopping the tunnel then would flap a path the
      // backend just vouched for. Keep the tunnel up in that case without
      // consuming the heal budget — unless the handshake is hard-stalled, in
      // which case the reachable backend was out-of-band and the tunnel path
      // is still dead.
      if (_backendLooksReachable() && !hardStalled) {
        AppLog.info('auto-heal suppressed ($why) backend reachable');
        snap = snap.copyWith(
          phase: ConnPhase.connected,
          message: 'Connected',
          autoHealAttempts: attempt - 1,
          healthNote: null,
          backendIssue: null,
        );
        return;
      }
      await _stopTunnel('auto-heal');
      if (sessionEpoch != _sessionEpoch) return;
      try {
        await _startWith(
          dial,
          preservePollFailures: true,
          sessionEpoch: sessionEpoch,
        );
        if (sessionEpoch != _sessionEpoch) return;
      } catch (e) {
        if (sessionEpoch != _sessionEpoch) return;
        final vpnErr = asVpnError(e);
        AppLog.error('auto-heal restart failed', vpnErr?.message ?? e);
        snap = snap.copyWith(
          phase: ConnPhase.error,
          message:
              'VPN stalled ($why). Restart failed (${vpnErr?.message ?? e}). Tap Connect.',
        );
        return;
      }
      // [_startWith] resets session health; re-assert the attempt count
      // while preserving the failover budget and poll evidence.
      snap = snap.copyWith(
        autoHealAttempts: attempt,
        autoFailoverAttempts: prevFailovers,
        pollFailures: prevPollFailures,
      );
      AppLog.info('auto-heal ok ($why) attempt=$attempt');
    } finally {
      release();
    }
  }

  /// Terminal state when the automatic ladder has nothing left to try: the
  /// move budget is spent and the trailing same-server restarts
  /// ([ConnectionTuning.maxHealsAfterMoveBudget]) did not restore the
  /// tunnel. Without this a corroborated stall would keep healing the same
  /// config every tick forever, with no user-visible signal. Stops the
  /// proven-dead tunnel, stops the ticks, clears the session budgets and
  /// surfaces an actionable error; the next Connect starts from a clean
  /// budget. Acquires [_mutex] and re-checks the phase, so a concurrent
  /// user op that took over during the tick's awaits is never clobbered.
  Future<void> _surfaceRecoveryExhausted(
    String why, {
    bool hardStalled = false,
    int? expectedSession,
    int? expectedEpoch,
    DialParams? expectedDial,
  }) async {
    final sessionEpoch = expectedSession ?? _sessionEpoch;
    final release = await _mutex.acquire('recovery-exhausted');
    try {
      if (sessionEpoch != _sessionEpoch ||
          (expectedEpoch != null && expectedEpoch != _tunnelEpoch) ||
          (expectedDial != null && !identical(snap.dial, expectedDial)) ||
          (!hardStalled && _lastStatusAnswered) ||
          snap.phase != ConnPhase.connected) {
        return;
      }
      AppLog.info('recovery exhausted ($why) ${_healBudgets()}');
      await _stopTunnel('recovery-exhausted');
      if (sessionEpoch != _sessionEpoch) return;
      _stopPolling();
      _pollsSinceRotate = 0;
      _resetLocalHealth();
      snap = _resetSessionCounters(
        snap.copyWith(
          phase: ConnPhase.error,
          message:
              'Automatic recovery failed ($why). No reachable server. '
              'Tap Connect to retry.',
          lastStage: null,
          healthNote: null,
          backendIssue: null,
        ),
      );
    } finally {
      release();
    }
  }

  /// Automatic move to a different server when the current one stays dead
  /// through [ConnectionTuning.failoverHealThreshold] same-server heal.
  /// Stops the tunnel first so region discovery and the switch POST travel
  /// over the direct network (the live tunnel points at the dead server,
  /// and status polls through it are what timed out in the first place).
  /// Picks same-region-first, then global lowest-load (see
  /// [pickFailoverTarget]) — unless the target is an explicit user pin,
  /// which never leaves the selected region and surfaces an error when it
  /// has no capacity left. Transport failures restart the old tunnel and
  /// stay connected so the next health tick retries until
  /// [ConnectionTuning.maxAutoFailovers] is spent; a 404 forgets the device
  /// like `pollStatusOnce` does.
  ///
  /// [tunnelPathDead] is the path-already-suspect fast-track: a
  /// performed-dead in-tunnel gateway echo, a hard-stale handshake, an
  /// unreachable control probe, or simply a stall that survived a
  /// same-server restart. The tunnel is stopped before discovery so the
  /// region fetch and the switch POST travel direct instead of probing a
  /// path already known bad.
  Future<void> _autoFailover(
    String why, {
    bool tunnelPathDead = false,
    bool hardStalled = false,
    int? expectedSession,
    int? expectedEpoch,
    DialParams? expectedDial,
  }) async {
    final sessionEpoch = expectedSession ?? _sessionEpoch;
    final release = await _mutex.acquire('auto-failover');
    try {
      if (expectedSession != null && expectedSession != _sessionEpoch) return;
      if (expectedEpoch != null && expectedEpoch != _tunnelEpoch) return;
      if (expectedDial != null && !identical(snap.dial, expectedDial)) {
        return;
      }
      if (!hardStalled && _lastStatusAnswered) return;
      await _autoFailoverBody(
        why,
        tunnelPathDead: tunnelPathDead,
        hardStalled: hardStalled,
        expectedSession: sessionEpoch,
        expectedEpoch: expectedEpoch,
        expectedDial: expectedDial,
      );
    } catch (e) {
      AppLog.error('auto-failover unexpected failure', e);
      if (sessionEpoch != _sessionEpoch) return;
      if (snap.phase == ConnPhase.working) {
        _stopPolling();
        snap = snap.copyWith(
          phase: ConnPhase.error,
          message:
              'Automatic recovery failed ($why). '
              'The device could not be updated. Tap Connect to retry.',
          lastStage: null,
          healthNote: null,
          backendIssue: null,
        );
      } else if (snap.phase == ConnPhase.connected) {
        snap = snap.copyWith(
          healthNote:
              'Automatic recovery paused ($why). '
              'Device identity is temporarily unavailable.',
        );
      }
    } finally {
      release();
    }
  }

  /// Lock-free failover body: caller must hold [_mutex] (see [_autoFailover]).
  Future<void> _autoFailoverBody(
    String why, {
    bool tunnelPathDead = false,
    bool hardStalled = false,
    int? expectedSession,
    int? expectedEpoch,
    DialParams? expectedDial,
  }) async {
    if (expectedSession != null && expectedSession != _sessionEpoch) return;
    if (expectedEpoch != null && expectedEpoch != _tunnelEpoch) return;
    if (expectedDial != null && !identical(snap.dial, expectedDial)) {
      return;
    }
    if (!hardStalled && _lastStatusAnswered) return;
    final oldDial = snap.dial;
    if (oldDial == null) return;
    if (snap.phase != ConnPhase.connected) return;
    final sessionEpoch = _sessionEpoch;
    final id = await _device.deviceId();
    if (sessionEpoch != _sessionEpoch ||
        snap.phase != ConnPhase.connected ||
        !identical(snap.dial, oldDial)) {
      return;
    }
    if (id == null) {
      AppLog.info('failover skipped (device identity unavailable)');
      snap = snap.copyWith(
        healthNote:
            'Automatic recovery paused ($why). '
            'Device identity is temporarily unavailable.',
      );
      return;
    }
    // Respect an active 429 cooldown: retrying discovery/switch now only
    // spends more of the shared limiter budget. Stay connected — the next
    // health tick retries once the window reopens.
    if (_rateLimitRemaining != null) {
      AppLog.info('failover skipped (rate limited)');
      return;
    }
    final attempt = snap.autoFailoverAttempts + 1;
    AppLog.info(
      'failover start ($why) attempt=$attempt server=${oldDial.serverName} '
      '${_healBudgets()}',
    );
    snap = snap.copyWith(
      phase: ConnPhase.working,
      message: 'Trying another server…',
      autoFailoverAttempts: attempt,
      healthNote: 'Server unreachable ($why). Trying another server…',
    );
    bool sessionCurrent() => sessionEpoch == _sessionEpoch;
    // A path-already-dead tunnel is stopped before discovery; otherwise
    // probe discovery through the live tunnel first and stop only when the
    // backend is unreachable through it (transport failure), so the
    // working path is never flapped. `tunnelDown` tracks the teardown so
    // every later branch stops exactly once and restarts safely.
    var tunnelDown = false;
    List<Region>? regions;
    if (tunnelPathDead) {
      await _stopTunnel('auto-failover');
      if (!sessionCurrent()) return;
      tunnelDown = true;
    } else if (_tunnel.isReady) {
      try {
        regions = await _probeThroughTunnel(
          (cancel) => _api.regions(cancelToken: cancel),
          'failover discovery',
          timeout: ConnectionTuning.recoveryProbeTimeout,
        );
        if (!sessionCurrent()) return;
      } catch (e) {
        // App-level rejection with the tunnel still up: the backend is
        // reachable, so keep the tunnel instead of flapping it. The next
        // health tick retries within the remaining failover budget.
        AppLog.error('failover discovery failed', e);
        if (!sessionCurrent()) return;
        _noteRateLimit(asVpnError(e));
        _keepConnected();
        return;
      }
    }
    if (regions == null && !tunnelDown) {
      await _stopTunnel('auto-failover');
      if (!sessionCurrent()) return;
      tunnelDown = true;
    }
    if (regions == null) {
      try {
        regions = await _api.regions();
        if (!sessionCurrent()) return;
      } catch (e) {
        AppLog.error('failover discovery failed', e);
        _noteRateLimit(asVpnError(e));
        await _restartOldDial(
          oldDial,
          why,
          tunnelDown: tunnelDown,
          sessionEpoch: sessionEpoch,
        );
        return;
      }
    }
    if (!sessionCurrent()) return;
    final target = _pickFailoverTarget(regions, oldDial);
    if (target == null) {
      if (snap.explicitTarget) {
        // Pinned region/server with no same-region capacity: never roam
        // across regions. The tunnel is down before the error is surfaced
        // so no tunnel runs behind the error.
        final pinned = snap.regionId ?? snap.serverId ?? oldDial.serverName;
        AppLog.info('failover pinned no-capacity ($pinned)');
        if (!tunnelDown) {
          await _stopTunnel('auto-failover');
          if (!sessionCurrent()) return;
          tunnelDown = true;
        }
        if (!sessionCurrent()) return;
        _stopPolling();
        _pollsSinceRotate = 0;
        snap = snap.copyWith(
          phase: ConnPhase.error,
          message:
              'No servers available in the selected region ($why). '
              'Pick another region or tap Connect to retry.',
          healthNote: null,
          backendIssue: null,
          lastStage: null,
        );
        return;
      }
      AppLog.info('failover no-capacity server=${oldDial.serverName}');
      // Nowhere to move (single-server deployment?): restart the old
      // tunnel like an offline heal. The failover budget keeps the
      // momentum so the stall keeps healing instead of looping. There is
      // no config-refresh fallback left, so a reboot-rotated server key
      // can only be picked up by a manual reconnect.
      await _restartOldDial(
        oldDial,
        why,
        tunnelDown: tunnelDown,
        sessionEpoch: sessionEpoch,
      );
      // Say why we stayed put after the restart reconnects.
      if (snap.phase == ConnPhase.connected &&
          snap.dial?.serverId == oldDial.serverId &&
          snap.dial?.wgPublicKey == oldDial.wgPublicKey) {
        snap = snap.copyWith(
          healthNote:
              'Server unreachable ($why). No other server available — '
              'staying put while recovery is attempted.',
        );
      }
      return;
    }
    // Ephemeral until the switch binds it (same pattern as switchServer:
    // persisting first would clobber the working key on a timeout).
    // Failures before the keypair is persisted fall back to the old
    // tunnel so a failover attempt never strands the user with nothing
    // running; failures after are surfaced as `error` (the server may
    // already hold the new key, so the old tunnel is no longer valid).
    DialParams dial;
    String newPriv;
    String newPub;
    try {
      final kp = await _keys.generate();
      // Probe the switch through the live tunnel first when it is still
      // up; stop only on transport failure, then retry direct. App-level
      // errors keep the tunnel up and fall back to the old dial below.
      final switched = await _postViaTunnelOrDirect(
        post: ({Duration? timeout}) => _switchPost(
          id,
          kp.publicKey,
          target.regionId,
          target.serverId,
          timeout: timeout,
        ),
        wasConnected: !tunnelDown,
        stopLabel: 'auto-failover',
        initiallyDown: tunnelDown,
        probeTimeout: ConnectionTuning.recoveryProbeTimeout,
      );
      tunnelDown = switched.tunnelDown;
      if (switched.dial == null) {
        AppLog.error('failover switch network-failed', 'transport failure');
        await _restartOldDial(
          oldDial,
          why,
          tunnelDown: tunnelDown,
          sessionEpoch: sessionEpoch,
        );
        return;
      }
      dial = switched.dial!;
      newPriv = kp.privateKey;
      newPub = kp.publicKey;
    } on DioException catch (e) {
      final kind = asVpnError(e)?.kind;
      _noteRateLimit(asVpnError(e));
      if (kind == ApiErrorKind.notFound) {
        if (!sessionCurrent()) return;
        AppLog.info('failover 404 -> forget device');
        await _forgetDeviceAndIdle(
          stopReason: tunnelDown ? null : 'auto-failover',
        );
        return;
      }
      if (kind == ApiErrorKind.noActivePeer) {
        AppLog.info('failover peerless -> rebind fresh peer');
        await _rebindAfterPeerless(
          id: id,
          target: target,
          why: why,
          attempt: attempt,
          tunnelDown: tunnelDown,
          sessionEpoch: sessionEpoch,
        );
        return;
      }
      // App-level rejection with the tunnel still up proves the backend
      // reachable: keep the tunnel instead of flapping it.
      AppLog.error('failover switch failed', e);
      if (!sessionCurrent()) return;
      if (!tunnelDown) {
        _keepConnected();
        return;
      }
      await _restartOldDial(
        oldDial,
        why,
        tunnelDown: tunnelDown,
        sessionEpoch: sessionEpoch,
      );
      return;
    } catch (e) {
      AppLog.error('failover move failed', e);
      if (!sessionCurrent()) return;
      if (!tunnelDown) {
        _keepConnected();
        return;
      }
      await _restartOldDial(
        oldDial,
        why,
        tunnelDown: tunnelDown,
        sessionEpoch: sessionEpoch,
      );
      return;
    }
    if (!sessionCurrent()) return;
    // Only now does the new key become the stored identity: it matches
    // the freshly bound server-side peer.
    try {
      await _device.setKeypair(privateKey: newPriv, publicKey: newPub);
    } catch (e) {
      AppLog.error('failover keypair persist failed', e);
      if (!sessionCurrent()) return;
      if (!tunnelDown) await _stopTunnel('auto-failover-persist-failed');
      _stopPolling();
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message:
            'Server unreachable ($why). Could not save the recovered key. '
            'Tap Connect to retry.',
        lastStage: null,
        healthNote: null,
        backendIssue: null,
      );
      return;
    }
    if (!sessionCurrent()) return;
    if (!tunnelDown) {
      // Through-tunnel switch success: single stop for the restart.
      await _stopTunnel('auto-failover-restart');
      if (!sessionCurrent()) return;
      tunnelDown = true;
    }
    try {
      await _startWith(dial, sessionEpoch: sessionEpoch);
      if (!sessionCurrent()) return;
    } catch (e) {
      if (!sessionCurrent()) return;
      final vpnErr = asVpnError(e);
      AppLog.error('failover restart failed', vpnErr?.message ?? e);
      _stopPolling();
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message:
            'Server unreachable ($why). Move failed (${vpnErr?.message ?? e}). Tap Connect.',
        lastStage: null,
      );
      return;
    }
    _recordAutoFailoverSuccess(dial, target, attempt, why);
  }

  void _recordAutoFailoverSuccess(
    DialParams dial,
    ({String? regionId, String? serverId}) target,
    int attempt,
    String why,
  ) {
    // [_startWith] resets heal health; re-assert the failover budget and
    // grant the new server fresh heals.
    snap = snap.copyWith(autoFailoverAttempts: attempt, autoHealAttempts: 0);
    // A pinned target re-pins onto the move so reconnects keep it; an
    // unpinned (Auto) state stays unpinned so later connects re-pick.
    if (snap.regionId != null || snap.serverId != null) {
      selectTarget(regionId: target.regionId, serverId: target.serverId);
    }
    AppLog.info(
      'failover ok ($why) attempt=$attempt server=${dial.serverName}',
    );
  }

  /// Rebinds a fresh peer after an automatic switch discovers that the
  /// device was peerless. This mirrors the manual switch recovery instead of
  /// restarting the stale cached dial.
  Future<void> _rebindAfterPeerless({
    required String id,
    required ({String? regionId, String? serverId}) target,
    required String why,
    required int attempt,
    required bool tunnelDown,
    required int sessionEpoch,
  }) async {
    if (sessionEpoch != _sessionEpoch) return;
    try {
      if (!tunnelDown) {
        await _stopTunnel('auto-failover-peerless');
        if (sessionEpoch != _sessionEpoch) return;
      }
      final fresh = await _bindFreshPeer(
        id,
        regionId: target.regionId,
        serverId: target.serverId,
        sessionEpoch: sessionEpoch,
      );
      if (sessionEpoch != _sessionEpoch) return;
      await _startWith(fresh, sessionEpoch: sessionEpoch);
      if (sessionEpoch != _sessionEpoch) return;
      _recordAutoFailoverSuccess(fresh, target, attempt, why);
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error('failover peerless rebind failed', vpnErr?.message ?? e);
      _stopPolling();
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message:
            'Server unreachable ($why). Reconnect failed '
            '(${vpnErr?.message ?? e}). Tap Connect.',
        lastStage: null,
        healthNote: null,
        backendIssue: null,
      );
    }
  }

  /// Resolves the failover target for [oldDial] against fresh [regions].
  /// An explicit user pin constrains the move to the selected region: a
  /// region pin applies directly, a server pin resolves to its parent
  /// region via discovery (same-region moves stay allowed). An
  /// unresolvable parent means no verifiable same-region capacity, so the
  /// pinned no-capacity error applies instead of a cross-region move.
  ({String? regionId, String? serverId})? _pickFailoverTarget(
    List<Region> regions,
    DialParams oldDial,
  ) {
    final explicit = snap.explicitTarget;
    String? failoverRegionId = snap.regionId;
    if (explicit && failoverRegionId == null) {
      final pinnedServer = snap.serverId ?? oldDial.serverId;
      for (final r in regions) {
        if (r.servers.any((s) => s.id == pinnedServer)) {
          failoverRegionId = r.id;
          break;
        }
      }
    }
    return pickFailoverTarget(
      regions: regions,
      currentRegionId: failoverRegionId,
      currentServerId: oldDial.serverId,
      stayInRegion: explicit,
    );
  }

  /// Restarts the previous tunnel after a failed failover step (dead
  /// discovery, no capacity, transport failure). The store still holds the
  /// old keypair — the replacement key is only persisted on switch success
  /// — so [_startWith] redials the old server and the next health tick
  /// retries until the failover budget is spent. Never throws: a restart
  /// failure surfaces `error` like [_autoHeal] does.
  ///
  /// [tunnelDown] tells whether the tunnel was already stopped for the
  /// direct fetch: when false (probe-first path where the fetch never
  /// needed the stop), the tunnel is stopped here so [_startWith] — which
  /// only stops a `connected` tunnel, while heal phases are `working` —
  /// never runs two live tunnels.
  Future<void> _restartOldDial(
    DialParams oldDial,
    String why, {
    bool tunnelDown = true,
    required int sessionEpoch,
  }) async {
    // The failover count was already incremented before the tunnel stop;
    // [_startWith] resets it, so preserve it across the fallback restart.
    // Poll failures are preserved for the same reason as in [_autoHeal]:
    // the outage is still ongoing.
    final failovers = snap.autoFailoverAttempts;
    final pollFailures = snap.pollFailures;
    if (sessionEpoch != _sessionEpoch) return;
    if (!tunnelDown) {
      await _stopTunnel('failover-fallback');
      if (sessionEpoch != _sessionEpoch) return;
    }
    try {
      await _startWith(
        oldDial,
        preservePollFailures: true,
        sessionEpoch: sessionEpoch,
      );
      if (sessionEpoch != _sessionEpoch) return;
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error('failover fallback restart failed', vpnErr?.message ?? e);
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message:
            'Server unreachable ($why). Restart failed (${vpnErr?.message ?? e}). Tap Connect.',
      );
      return;
    }
    // [_startWith] clears heal health; the failover count was already
    // incremented before the tunnel stop, so it survives here by design.
    snap = snap.copyWith(
      autoHealAttempts: 0,
      autoFailoverAttempts: failovers,
      pollFailures: pollFailures,
    );
    AppLog.info('failover fallback ok ($why) server=${oldDial.serverName}');
  }
}
