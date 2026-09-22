part of 'connection_controller.dart';

/// Banner shown while the OS reports no usable link. Set immediately by
/// [_onLinkChanged] and re-asserted by the health tick.
const _noNetworkNote =
    'Waiting for network… Reconnecting when connection returns.';

extension ConnectionHealth on ConnectionController {
  /// One local health tick: handshake + stage stall detection with offline
  /// auto-heal, escalating straight to an automatic server move (see
  /// [_autoHeal], [_autoFailover]). Public so tests can drive a tick without
  /// waiting [PollingService.healthCheckInterval]. The heal path never calls
  /// the backend; failover stops the tunnel first so its control-plane calls
  /// travel over the direct network. Once the move budget and the trailing
  /// restarts are spent, a corroborated stall surfaces an actionable error
  /// instead (see [_surfaceRecoveryExhausted]).
  Future<void> _healthCheckOp() async {
    if (snap.phase != ConnPhase.connected) return;
    if (_mutex.isLocked) return;
    if (!_tunnel.isReady) return;
    final dial = snap.dial;
    if (dial == null) return;
    final now = _clock.now();
    // Stage + handshake + traffic are independent reads: run them
    // concurrently so a slow one doesn't push detection past the next tick.
    // Each read has its own short health timeout (a wedged driver reports
    // null = unknown, never a stall on its own). Traffic stays display-only
    // for the Home card; heal decisions use the handshake plus the echo. The
    // in-tunnel echo is read below only when it can matter (see
    // [ConnectionTuning.echoProbeAfter]): it is the only per-tick network
    // I/O in the health path, and a fresh handshake already proves the peer
    // alive. A record `.wait` keeps the result types explicit (no index
    // casts) while still running the reads concurrently. None of them
    // throws: the adapter and the handshake reader resolve failures as null.
    final (stage, handshake, traffic) = await (
      _tunnel.readStage(),
      _readHandshake(),
      // Display-only, foreground-only: in the background the read would
      // subscribe to the plugin's traffic EventChannel and spin up its
      // per-second native monitor (plus a SharedPreferences write) just to
      // refresh a hidden counter. Null means "unknown", which the publish
      // below already handles.
      _backgrounded
          ? Future<Map<String, dynamic>?>.value()
          : _tunnel.readTraffic(),
    ).wait;
    if (stage != null && stage != snap.lastStage) {
      _noteStage(stage);
      if (snap.phase != ConnPhase.connected) return;
      // An outside-stop verification owns the outcome from here: healing
      // underneath it would restart a tunnel the verification may be about
      // to tear down (or re-heal one it just adopted).
      if (snap.healthNote == _externalStopVerifyingNote) return;
    }
    // Re-drive an unresolved outside-stop verification each tick: the first
    // round may have seen only unknown evidence (null handshake, skipped
    // gateway probe), which defers — a truly dead tunnel becomes
    // stale-confirmed with time and tears down on a later round.
    if (snap.phase == ConnPhase.connected &&
        snap.lastStage == VpnStage.disconnected &&
        snap.healthNote == _externalStopVerifyingNote) {
      final dial = snap.dial;
      if (dial != null && !_mutex.isLocked) {
        await _corroborateExternalStop(_tunnelEpoch, dial);
        if (snap.phase != ConnPhase.connected) return;
        if (snap.healthNote == _externalStopVerifyingNote) return;
      }
    }
    // Publish counters for the Home card (and Settings debug line).
    // Null means the plugin reported no usable counter — the UI hides
    // the section instead of showing a misleading zero.
    final rx = traffic == null ? null : extractRxBytes(traffic);
    final tx = traffic == null ? null : extractTxBytes(traffic);
    if (rx != null || tx != null) {
      final nextRx = rx ?? snap.rxBytes;
      final nextTx = tx ?? snap.txBytes;
      if (nextRx != snap.rxBytes || nextTx != snap.txBytes) {
        snap = snap.copyWith(rxBytes: nextRx, txBytes: nextTx);
      }
    }
    // A performed-dead run of echoes (never a null/unknown read) shortens
    // the dead-peer handshake window below: the in-tunnel probe is a direct
    // liveness check on the WireGuard data path, so three consecutive dead
    // ticks are stronger evidence than a rekey-timer stopwatch. Any
    // alive/unknown echo clears the run.
    //
    // The probe is read only when it can matter. A fresh handshake already
    // proves the peer alive, so probing every tick while it is fresh is pure
    // steady-state traffic; probe once the handshake is old enough for a
    // missing rekey to mean anything ([ConnectionTuning.echoProbeAfter]), or
    // whenever a degraded stage may need the echo to tell a flap from a dead
    // path. An unknown handshake (never handshook, or no reader on this
    // platform) keeps probing — the echo is then the only local signal.
    // Skipping clears the run: a fresh handshake is positive liveness.
    final stageStalled =
        stage != null && _isDegradedStage(stage) && snap.pollFailures >= 1;
    final handshakeAge = handshake == null ? null : now.difference(handshake);
    final probeEcho =
        stageStalled ||
        handshakeAge == null ||
        handshakeAge >= ConnectionTuning.echoProbeAfter;
    final bool? gateway;
    if (probeEcho) {
      gateway = await _gatewayAlive(dial.wgDns);
      _deadEchoStrikes = gateway == false ? _deadEchoStrikes + 1 : 0;
    } else {
      gateway = null;
      _deadEchoStrikes = 0;
    }
    final echoShortens = _deadEchoStrikes >= ConnectionTuning.echoStallStrikes;
    // A stale handshake alone can't tell a dead peer from an unreachable
    // control plane, so it needs backend corroboration (a poll failure or
    // a quiet backend): a recently proven reachable backend suppresses the
    // heal entirely. Never-polled (outage before the first 60s poll)
    // counts as quiet, preserving fast detection. A null read is split by
    // reader support (see [isHandshakeStale]): with a working reader it
    // means "never handshook" (stale after the grace window), without one
    // it is absence of evidence and never heals — the degraded-stage path
    // above still covers those platforms.
    final standardStalled =
        isHandshakeStale(
          lastHandshakeAt: handshake,
          now: now,
          connectedAt: _connectedAt,
          readerSupported: _readerSupported,
          graceAfter: ConnectionTuning.firstHandshakeGrace,
          // A corroborated dead echo collapses the 150s rekey window to a
          // ~30s one, so a mid-session server death is detected in well
          // under a minute instead of minutes. The never-handshook branch
          // still uses [ConnectionTuning.firstHandshakeGrace].
          staleAfter: echoShortens
              ? ConnectionTuning.echoStallHandshakeAge
              : ConnectionTuning.handshakeStaleAfter,
        ) &&
        isBackendCorroborated(
          pollFailures: snap.pollFailures,
          lastStatusAt: snap.lastStatusAt,
          now: now,
        );
    // Hard ceiling: past [ConnectionTuning.hardHandshakeStaleAfter]
    // (observed) or [ConnectionTuning.hardFirstHandshakeCeiling] after a
    // restart (never handshook), the handshake acts *without* backend
    // corroboration. A reachable out-of-band control plane (WG UDP blocked,
    // API up) keeps polls succeeding, so corroboration never arrives and the
    // ladder would otherwise sit in the stall state forever; the ceiling
    // makes recovery deterministic. It only enters the stall — the
    // fast-track rung still needs a reachable control plane (see
    // [classifyFailure]). An unsupported reader's null stays absence of
    // evidence.
    final hardStalled = isHandshakeStale(
      lastHandshakeAt: handshake,
      now: now,
      connectedAt: _connectedAt,
      readerSupported: _readerSupported,
      graceAfter: ConnectionTuning.hardFirstHandshakeCeiling,
      staleAfter: ConnectionTuning.hardHandshakeStaleAfter,
    );
    final handshakeStalled = standardStalled || hardStalled;
    if (!stageStalled && !handshakeStalled) return;
    final String why;
    if (handshakeStalled) {
      final age = handshake == null
          ? 'never'
          : '${now.difference(handshake).inSeconds}s';
      if (hardStalled) {
        why = 'handshake hard-stale ($age)';
      } else if (echoShortens) {
        why = 'handshake stale ($age), echo dead ×$_deadEchoStrikes';
      } else {
        why = 'handshake stale ($age)';
      }
    } else {
      why = 'stage=${snap.lastStage?.name ?? 'unknown'}';
    }
    // 4-layer diagnostic pipeline (see `domain/diagnosis_policy.dart`):
    // Layer 2 (physical link) → Layer 1 (in-tunnel gateway echo) →
    // Layer 3 (control-plane probe) → Layer 4 (classified escalation).
    // Probes are read-only: none of them consumes heal/refresh/failover
    // budgets or touches `pollFailures` — only the terminal action below
    // does, under the existing caps.
    if (!await _hasLink()) {
      AppLog.info('health paused ($why) no local network');
      if (snap.phase != ConnPhase.connected) return;
      snap = snap.copyWith(healthNote: _noNetworkNote);
      return;
    }
    // Reuse this tick's echo read (already computed above); a live echo
    // proves the data path, so the stall is a transient flap.
    if (gateway == true) {
      AppLog.info('health suppressed ($why) gateway echo alive');
      return;
    }
    // Nothing left to try: the move budget is spent and the trailing
    // same-server restarts did not restore the tunnel. Surface an
    // actionable error instead of heal-looping the proven-dead config
    // forever. Checked before the classifier so the exhausted path never
    // spends another control-plane probe.
    if (snap.autoFailoverAttempts >= ConnectionTuning.maxAutoFailovers &&
        snap.autoHealAttempts >= ConnectionTuning.maxHealsAfterMoveBudget) {
      await _surfaceRecoveryExhausted(why);
      return;
    }
    final apiReachable = await _apiReachable();
    final cause = classifyFailure(
      hasNetwork: true,
      gatewayAlive: gateway,
      apiReachable: apiReachable,
      hardStalled: hardStalled,
    );
    if (cause == ConnectionFailureCause.tunnelPathDead) {
      // The control plane answers directly but the tunnel path is dead —
      // either a performed dead echo or a handshake that stayed dead past
      // the hard ceiling (the echo may be unprobeable). The cached config
      // can't recover on its own, so go straight to a server move instead of
      // burning a heal cycle. The tunnel is stopped before discovery (see
      // [_autoFailover]) since the path is already proven dead, so no probe
      // is wasted on it.
      if (snap.autoFailoverAttempts < ConnectionTuning.maxAutoFailovers) {
        AppLog.info('health fast-track ($why) path dead, api up -> failover');
        await _autoFailover(why, tunnelPathDead: true);
        return;
      }
    }
    if (shouldEscalateToFailover(
      autoHealAttempts: snap.autoHealAttempts,
      autoFailoverAttempts: snap.autoFailoverAttempts,
      pollFailures: snap.pollFailures,
      healThreshold: ConnectionTuning.failoverHealThreshold,
      lastStatusAt: snap.lastStatusAt,
      now: now,
    )) {
      // A corroborated stall that already survived a same-server restart has
      // proven the cached path dead: stop before discovery so the region
      // fetch and the switch POST travel over the direct network instead of
      // waiting out a probe on a path known bad. `null` probe evidence
      // (unknown) keeps the probe-first behavior — absence of evidence must
      // never flap a path that may still be alive.
      final pathDead = hardStalled || gateway == false || apiReachable == false;
      await _autoFailover(why, tunnelPathDead: pathDead);
    } else {
      await _autoHeal(why, hardStalled: hardStalled);
    }
  }

  /// OS link transition (see [NetworkMonitor.linkChanges]).
  ///
  /// Link down: surface the outage immediately instead of waiting for the
  /// next health tick. Link up: clear that banner and run the resume
  /// catch-up — a backend-free health tick, then a status poll only when the
  /// snapshot is stale — so a tunnel that went quiet while the link was down
  /// is healed at once. Both paths no-op unless the tunnel is connected (the
  /// health tick and catch-up re-check anyway).
  void _onLinkChanged(bool hasLink) {
    if (snap.phase != ConnPhase.connected) return;
    if (!hasLink) {
      snap = snap.copyWith(healthNote: _noNetworkNote);
      return;
    }
    if (snap.healthNote == _noNetworkNote) {
      snap = snap.copyWith(healthNote: null);
    }
    unawaited(_catchUpOnResumeOp());
  }

  /// Layer 2 read: OS physical-link state. Fail-open (true) so a broken
  /// plugin can never pause healing forever.
  Future<bool> _hasLink() async {
    try {
      return await _networkMonitor.hasLink();
    } catch (e) {
      AppLog.error('network link read failed (assuming online)', e);
      return true;
    }
  }

  /// Layer 1 read: in-tunnel gateway echo against a probeable IP in
  /// `wgDns` (see [firstDnsProbeIp]). Tri-state: true = alive (suppresses
  /// healing), false = echoed-dead, null = skipped or errored — unknown,
  /// never proof of death on its own (the classifier can't fast-track on
  /// it and the external-stop verifier defers on it).
  Future<bool?> _gatewayAlive(String wgDns) async {
    final target = firstDnsProbeIp(wgDns);
    if (target == null) {
      // Never expected in production (wg_dns is the server's tunnel IP);
      // logged so a mis-shaped dial value can't hide as a silent "skipped".
      AppLog.info('gateway probe skipped (no probeable IP in dns=$wgDns)');
      return null;
    }
    try {
      return await _gatewayProbe.echoDns(
        target,
        timeout: ConnectionTuning.gatewayProbeTimeout,
      );
    } catch (e) {
      AppLog.error('gateway echo failed', e);
      return null;
    }
  }

  /// Layer 3 read: out-of-band control-plane reachability. Null means
  /// unknown (errored probe, or a loopback API the probe skips — see
  /// [ControlPlaneProbe.check]) — the classifier falls back to the legacy
  /// ladder instead of fast-tracking on absence of evidence.
  Future<bool?> _apiReachable() async {
    try {
      return await _controlPlaneProbe.check();
    } catch (e) {
      AppLog.error('control probe failed', e);
      return null;
    }
  }
}
