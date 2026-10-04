part of 'connection_controller.dart';

/// Heal/failover escalation ladder for the connected tunnel.
///
/// Locally confirmed or backend-corroborated stalls restart the cached config
/// offline ([_autoHeal]);
/// a stall that survives that escalates straight to moving servers
/// ([_autoFailover]) — there is no same-server config refresh in between.
extension ConnectionRecovery on ConnectionController {
  /// Offline restart on the cached config: zero API calls, so it works
  /// with no network or a dead control plane. It runs once per failure
  /// incident; a persistent stall then waits for the control plane or
  /// escalates to failover (see [ConnectionTuning.maxHealsAfterMoveBudget]
  /// and [_surfaceRecoveryExhausted]).
  /// Never runs for auth/subscription failures: those leave `connected` via
  /// `pollStatusOnce`/the session listener, and the guards below return
  /// early outside `connected`.
  ///
  /// [hardStalled] (the handshake stayed dead past
  /// [ConnectionTuning.hardHandshakeStaleAfter]) bypasses the
  /// "backend reachable" suppression below: a status response does not prove
  /// the data path healthy when the handshake is hard-dead.
  ///
  /// [demoteTransport] is the ladder policy's verdict, not a re-derivation
  /// here: it is true only when the path looked dead while the control plane
  /// answered, which is the only evidence that this transport is blocked rather
  /// than the network being gone. Keeping it a parameter means this method
  /// cannot decide on its own to change rungs.
  Future<void> _autoHeal(
    String why, {
    bool hardStalled = false,
    bool localConfirmed = false,
    bool demoteTransport = false,
    RecoveryReason? recoveryReason,
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
      final promotionFallback = _promotionFallbackRung;
      if (promotionFallback == null &&
          !hardStalled &&
          !localConfirmed &&
          _lastStatusAnswered) {
        return;
      }
      // A status poll may have proven the backend reachable after the tick
      // scheduled this heal: stopping the tunnel then would flap a path the
      // backend just vouched for. Keep the tunnel up in that case without
      // consuming the heal budget — unless the handshake is hard-stalled, in
      // which case the reachable backend was out-of-band and the tunnel path
      // is still dead. Checked before the first write below so a suppressed
      // heal does not publish `working` and then walk it back, which cost
      // the UI two rebuilds and a visible "Reconnecting…" flicker.
      if (promotionFallback == null &&
          _backendLooksReachable() &&
          !hardStalled &&
          !localConfirmed) {
        AppLog.info('auto-heal suppressed ($why) backend reachable');
        snap = snap.copyWith(
          healthNote: null,
          backendIssue: null,
          recoveryAction: null,
          recoveryReason: null,
          recoveryDetail: null,
        );
        return;
      }
      final sessionEpoch = _sessionEpoch;
      final attempt = snap.autoHealAttempts + 1;
      // [_startWith] resets the failover budget; a same-server restart must
      // not consume or clear it. Poll failures are outage evidence, not
      // per-restart state: wiping them forces two fresh 60s polls after
      // every heal before the stall can escalate.
      final prevFailovers = snap.autoFailoverAttempts;
      final prevPollFailures = snap.pollFailures;
      final previousRung = _transportRung;
      final reason =
          recoveryReason ?? snap.recoveryReason ?? RecoveryReason.unknown;
      // A lower transport is warranted only when the data path looks dead
      // while the control plane is reachable. A blackout can still justify
      // restarting the cached config, but it is not evidence that this
      // transport specifically is blocked.
      if (promotionFallback != null) {
        _transportRung = promotionFallback;
        _promotionFallbackRung = null;
        _promotionFallbackDial = null;
        AppLog.info(
          'transport promotion failed ($why), reverting to '
          '${promotionFallback.name}',
        );
      } else if (demoteTransport) {
        _demoteRung(dial, why);
      }
      final action = _transportRung == previousRung
          ? RecoveryAction.restarting
          : switch (_transportRung) {
              TransportRung.native => RecoveryAction.restarting,
              TransportRung.awg => RecoveryAction.tryingAwg,
              TransportRung.stream => RecoveryAction.tryingStream,
            };
      AppLog.info('auto-heal start ($why) attempt=$attempt ${_healBudgets()}');
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Reconnecting…',
        autoHealAttempts: attempt,
        healthNote: 'VPN stalled ($why). Reconnecting…',
        recoveryAction: action,
        recoveryReason: reason,
        recoveryDetail: why,
      );
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
        // The tunnel is already down (it was stopped above), so this is a
        // terminal state like [_surfaceRecoveryExhausted]: stop the ticks
        // and drop the stage it died on rather than leaving stale reads
        // armed behind an error.
        _stopPolling();
        _pollsSinceRotate = 0;
        _resetLocalHealth();
        snap = snap.copyWith(
          phase: ConnPhase.error,
          message:
              'VPN stalled ($why). Restart failed (${failureReason(vpnErr, e)}). Tap Connect.',
          lastStage: null,
          healthNote: null,
          backendIssue: null,
        );
        return;
      }
      // [_startWith] resets session health; re-assert the attempt count
      // while preserving the failover budget and poll evidence.
      snap = snap.copyWith(
        autoHealAttempts: attempt,
        autoFailoverAttempts: prevFailovers,
        pollFailures: prevPollFailures,
        // Keep the connected phase from presenting a false healthy state
        // during the post-restart handshake deadline. A successful handshake
        // clears this note through the normal fresh-tunnel path.
        healthNote: _recoveryInProgressNote,
        recoveryAction: action,
        recoveryReason: reason,
        recoveryDetail: why,
      );
      AppLog.info('auto-heal ok ($why) attempt=$attempt');
    } finally {
      release();
    }
  }

  /// Terminal state when the automatic ladder has nothing left to try: the
  /// move budget is spent and the bounded same-server restart did not restore
  /// the tunnel. Without this a corroborated stall would keep healing the same
  /// config every tick forever, with no user-visible signal. Stops the
  /// proven-dead tunnel, stops the ticks, clears the session budgets and
  /// surfaces an actionable error; the next Connect starts from a clean
  /// budget. Acquires [_mutex] and re-checks the phase, so a concurrent
  /// user op that took over during the tick's awaits is never clobbered.
  Future<void> _surfaceRecoveryExhausted(
    String why, {
    bool hardStalled = false,
    bool localConfirmed = false,
    int? expectedSession,
    int? expectedEpoch,
    DialParams? expectedDial,
  }) async {
    final sessionEpoch = expectedSession ?? _sessionEpoch;
    final release = await _mutex.acquire('recovery-exhausted');
    try {
      if (!_sessionStillMatches(
            sessionEpoch: expectedSession,
            epoch: expectedEpoch,
            dial: expectedDial,
          ) ||
          (!hardStalled && !localConfirmed && _lastStatusAnswered) ||
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
  /// through [ConnectionTuning.failoverHealThreshold] same-server heal, or
  /// immediately when local evidence positively identifies a dead tunnel path.
  /// Stops the tunnel first so region discovery and the switch POST travel
  /// over the direct network (the live tunnel points at the dead server,
  /// and status polls through it are what timed out in the first place).
  /// Picks same-region-first, then global lowest-load (see
  /// [pickFailoverTarget]). An explicit user pin is only a preference: when
  /// its region has no other capacity, or the pinned server is gone from
  /// discovery, the move roams anyway and the pin drops to Auto rather than
  /// stranding the session on a dead server. Transport failures restart the
  /// old tunnel and stay connected so the next health tick retries until
  /// [ConnectionTuning.maxAutoFailovers] is spent; a 404 forgets the device
  /// like `pollStatusOnce` does. The budget is charged per committed
  /// attempt (a tunnel stop, a resolved target), not per entry: a call the
  /// backend *answers* while the tunnel stays up changed nothing, so it
  /// costs nothing and the tick cadence is the backoff.
  ///
  /// [tunnelPathDead] is the path-already-suspect fast-track: confirmed dead
  /// gateway echoes, a hard-stale handshake, a backend-confirmed-dead node,
  /// or a stall that survived a same-server restart. The tunnel is stopped
  /// before discovery so the region fetch and switch POST travel direct
  /// instead of probing a path already known bad.
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
      if (!_sessionStillMatches(
        sessionEpoch: expectedSession,
        epoch: expectedEpoch,
        dial: expectedDial,
      )) {
        return;
      }
      // Positive local path-dead evidence is stronger than an older status
      // response: that request may have used a route independent of the
      // WireGuard path that is already dead.
      if (!hardStalled && !tunnelPathDead && _lastStatusAnswered) return;
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
    if (!_sessionStillMatches(
      sessionEpoch: expectedSession,
      epoch: expectedEpoch,
      dial: expectedDial,
    )) {
      return;
    }
    if (!hardStalled && !tunnelPathDead && _lastStatusAnswered) return;
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
        recoveryAction: RecoveryAction.waiting,
        recoveryReason: RecoveryReason.deviceIdentityUnavailable,
        recoveryDetail: why,
      );
      return;
    }
    // Respect an active 429 cooldown: retrying discovery/switch now only
    // spends more of the shared limiter budget. Stay connected — the next
    // health tick retries once the window reopens.
    if (_rateLimitRemaining != null) {
      AppLog.info('failover skipped (rate limited)');
      snap = snap.copyWith(
        recoveryAction: RecoveryAction.waiting,
        recoveryReason: RecoveryReason.rateLimited,
        recoveryDetail: why,
      );
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
      healthNote: 'Server unreachable ($why). Trying another server…',
      recoveryAction: RecoveryAction.switchingServer,
      recoveryReason: snap.recoveryReason ?? RecoveryReason.unknown,
      recoveryDetail: snap.recoveryDetail ?? why,
    );
    // The move budget is charged at *commitment*, not on entry. A discovery
    // or switch POST the backend answers (5xx/429/…) proves the control plane
    // is reachable, so the tunnel is kept up and no move happened; charging
    // there spent the budget against servers the session was never on and
    // walked it into [_surfaceRecoveryExhausted] with the tunnel healthy.
    // Every path that stops the tunnel or issues the switch POST charges
    // first, so a real attempt still costs exactly one.
    void chargeAttempt() {
      snap = snap.copyWith(autoFailoverAttempts: attempt);
    }

    // The counterpart, for a move the backend *answered* while the tunnel
    // stayed up: the control plane is reachable and no server was changed,
    // so the budget goes back and the next tick may try again. A transport
    // failure (which tears the tunnel down and restarts it) keeps the
    // charge.
    void refundAttempt() {
      snap = snap.copyWith(autoFailoverAttempts: attempt - 1);
    }

    bool sessionCurrent() => sessionEpoch == _sessionEpoch;
    // A path-already-dead tunnel is stopped before discovery; otherwise
    // probe discovery through the live tunnel first and stop only when the
    // backend is unreachable through it (transport failure), so the
    // working path is never flapped. `tunnelDown` tracks the teardown so
    // every later branch stops exactly once and restarts safely.
    var tunnelDown = false;
    List<Region>? regions;
    if (tunnelPathDead) {
      chargeAttempt();
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
        // reachable, so keep the tunnel instead of flapping it. Nothing
        // moved, so the budget is untouched and the next health tick
        // retries at the tick cadence.
        AppLog.error('failover discovery failed', e);
        if (!sessionCurrent()) return;
        _noteRateLimit(asVpnError(e));
        _keepConnected();
        return;
      }
    }
    if (regions == null && !tunnelDown) {
      chargeAttempt();
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
    final pick = _pickFailoverTarget(regions, oldDial);
    final target = pick.serverId;
    if (target == null) {
      // Nowhere to move: the client deliberately bounces the old tunnel
      // instead, which is a committed move attempt like any other (the
      // budget is what keeps the stall from re-discovering forever). A pin
      // lands here too, but only when the whole deployment is out of
      // capacity — a dead *region* roams rather than stopping here.
      chargeAttempt();
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
        recoveryReason: RecoveryReason.noAlternativeServer,
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
    // A target is in hand: this is a committed move, so it costs an attempt
    // whether or not the switch POST below succeeds. Charging here (rather
    // than on entry) is what spares the discovery-only failures above.
    chargeAttempt();
    try {
      final kp = await _keys.generate();
      // Probe the switch through the live tunnel first when it is still
      // up; stop only on transport failure, then retry direct. App-level
      // errors keep the tunnel up and fall back to the old dial below.
      final switched = await _postViaTunnelOrDirect(
        post: ({Duration? timeout}) =>
            _switchPost(id, kp.publicKey, null, target, timeout: timeout),
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
          crossRegion: pick.crossRegion,
          regionName: pick.regionName,
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
        refundAttempt();
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
        refundAttempt();
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
    await _recordAutoFailoverSuccess(
      dial,
      target,
      attempt,
      why,
      crossRegion: pick.crossRegion,
      regionName: pick.regionName,
    );
  }

  Future<void> _recordAutoFailoverSuccess(
    DialParams dial,
    String? target,
    int attempt,
    String why, {
    required bool crossRegion,
    String? regionName,
  }) async {
    // [_startWith] resets heal health; re-assert the failover budget and
    // grant the new server fresh heals.
    snap = snap.copyWith(autoFailoverAttempts: attempt, autoHealAttempts: 0);
    // A same-region move re-pins onto the new server so reconnects keep it;
    // a cross-region move voids the pin instead (the region the user chose is
    // gone), and an unpinned (Auto) state stays unpinned either way so later
    // connects re-pick.
    if (snap.serverId != null) {
      if (crossRegion) {
        // The pin's region was dead or gone, so the pin is void: drop to Auto
        // rather than persisting a server in a region the user never chose.
        // [selectAuto] awaits the write, so a racing saved-target read cannot
        // resurrect the dead pin.
        await selectAuto();
        snap = snap.copyWith(
          healthNote:
              'Moved to ${regionName ?? 'another region'} — the selected '
              'region is unavailable. Back on Auto.',
        );
      } else {
        selectTarget(serverId: target);
      }
    }
    AppLog.info(
      'failover ok ($why) attempt=$attempt server=${dial.serverName}'
      '${crossRegion ? ' cross-region' : ''}',
    );
  }

  /// Rebinds a fresh peer after an automatic switch discovers that the
  /// device was peerless. This mirrors the manual switch recovery instead of
  /// restarting the stale cached dial.
  Future<void> _rebindAfterPeerless({
    required String id,
    required String? target,
    required bool crossRegion,
    required String? regionName,
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
        serverId: target,
        sessionEpoch: sessionEpoch,
      );
      if (sessionEpoch != _sessionEpoch) return;
      await _startWith(fresh, sessionEpoch: sessionEpoch);
      if (sessionEpoch != _sessionEpoch) return;
      await _recordAutoFailoverSuccess(
        fresh,
        target,
        attempt,
        why,
        crossRegion: crossRegion,
        regionName: regionName,
      );
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

  /// Resolves the failover server for [oldDial] against fresh [regions].
  ///
  /// An explicit user server pin resolves its parent region (via discovery)
  /// purely as a *preference*: same-region siblings are tried first, but when
  /// the pinned region has no other capacity — or the pinned server is gone
  /// from discovery entirely — the move roams to the lowest-load server
  /// anywhere rather than stranding the session on a dead one.
  ///
  /// [crossRegion] reports that the pick left the pinned region so the
  /// caller can drop the pin to Auto instead of persisting a server the user
  /// never chose. An unresolvable parent counts as cross-region: a pin whose
  /// server vanished is void whatever the replacement is.
  ({String? serverId, bool crossRegion, String? regionName})
  _pickFailoverTarget(List<Region> regions, DialParams oldDial) {
    Region? pinnedRegion;
    if (snap.explicitTarget) {
      final pinnedServer = snap.serverId ?? oldDial.serverId;
      for (final r in regions) {
        if (r.servers.any((s) => s.id == pinnedServer)) {
          pinnedRegion = r;
          break;
        }
      }
    }
    final target = pickFailoverTarget(
      regions: regions,
      currentRegionId: pinnedRegion?.id,
      currentServerId: oldDial.serverId,
    );
    if (target == null) {
      return (serverId: null, crossRegion: false, regionName: null);
    }
    Region? targetRegion;
    for (final r in regions) {
      if (r.servers.any((s) => s.id == target)) {
        targetRegion = r;
        break;
      }
    }
    final crossRegion =
        snap.explicitTarget && pinnedRegion?.id != targetRegion?.id;
    return (
      serverId: target,
      crossRegion: crossRegion,
      regionName: targetRegion?.name,
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
    RecoveryReason? recoveryReason,
  }) async {
    // Every path that reaches here has already charged its attempt (a
    // tunnel stop or a resolved target), but [_startWith] resets the
    // counter — so read it back and re-assert it across the restart.
    // Poll failures are preserved for the same reason as in [_autoHeal]:
    // the outage is still ongoing.
    final failovers = snap.autoFailoverAttempts;
    final pollFailures = snap.pollFailures;
    final reason =
        recoveryReason ?? snap.recoveryReason ?? RecoveryReason.unknown;
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
      recoveryAction: RecoveryAction.restarting,
      recoveryReason: reason,
      recoveryDetail: why,
    );
    AppLog.info('failover fallback ok ($why) server=${oldDial.serverName}');
  }
}
