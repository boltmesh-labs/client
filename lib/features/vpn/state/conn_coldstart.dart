part of 'connection_controller.dart';

extension ConnectionColdStart on ConnectionController {
  /// Foreground-resume catch-up (Option A). No timers: runs once per
  /// `resumed` event while connected. Always runs the backend-free health
  /// tick first (restores stale handshakes via the existing heal chain),
  /// then the backend status poll only when the last snapshot is stale
  /// (`>= [Env.statusPollInterval]`, honoring the session-budgeted
  /// `status_limiter`). Skips entirely when another op holds the mutex —
  /// its completion already reconciles state. Re-checks phase/lock after
  /// the health tick since healing may have failed over or torn down.
  Future<void> _catchUpOnResumeOp({DateTime? now}) async {
    if (snap.phase != ConnPhase.connected) return;
    if (_mutex.isLocked) return;
    await checkHealthOnce();
    if (snap.phase != ConnPhase.connected) return;
    if (_mutex.isLocked) return;
    final at = snap.lastStatusAt;
    final t = now ?? _clock.now();
    if (at != null && t.difference(at) < Env.statusPollInterval) return;
    await pollStatusOnce();
  }

  /// Cold-start reconciliation: the OS tunnel (Android VpnService) survives
  /// a killed Flutter process while [ConnState] resets to idle, so a reopen
  /// would otherwise show Disconnected with the VPN up. Queries the native
  /// stage and restores state without restarting the tunnel (`startVpn` is
  /// never called here):
  ///
  /// * `connected`/`noConnection` → optimistic Connected from the cached
  ///   dial (last-target label while offline), then confirmed against
  ///   `GET …/config` server truth;
  /// * transitional (`connecting`, `waitingConnection`, … — see
  ///   [isColdTransitionalStage]) → working ("Restoring connection…"),
  ///   then confirmed the same way;
  /// * down/terminal (`disconnected`, `disconnecting`, `denied`, …) with a
  ///   cached dial → working ("Restoring connection…"), then confirmed the
  ///   same way. A fresh backend in a re-attached engine reports no running
  ///   tunnels even when the OS TUN survived, so a lone `disconnected` read
  ///   is not trustworthy — server truth decides, and a confirmed peer
  ///   always bounces (stop + start) so this backend owns the TUN.
  ///   Without a cached dial (fresh install or explicit teardown) it stays
  ///   idle without touching the network;
  /// * anything else (down with no cache, unreadable stage with no cache)
  ///   → stay idle.
  ///
  /// A stale OS tunnel (peer GC'd/revoked while the app was dead) is
  /// stopped and reported as idle so the next Connect binds cleanly. Runs
  /// at startup and on resume-while-idle; warm-connected resumes keep using
  /// [catchUpOnResume]. Never throws: storage/network failures only log and
  /// leave the previous state.
  Future<void> _reconcileColdStartOp() async {
    final sessionEpoch = _sessionEpoch;
    if (snap.phase != ConnPhase.idle && snap.phase != ConnPhase.working) {
      return;
    }
    if (snap.dial != null || _mutex.isLocked) return;
    String? id;
    try {
      id = await _device.deviceId();
    } catch (e) {
      AppLog.error('cold restore device read failed', e);
      return;
    }
    if (id == null) return;
    // Re-check after the await: a user op or auth transition may have taken
    // over meanwhile.
    if (sessionEpoch != _sessionEpoch ||
        (snap.phase != ConnPhase.idle && snap.phase != ConnPhase.working)) {
      return;
    }
    if (snap.dial != null || _mutex.isLocked) return;
    try {
      await _ensureTunnelInit();
    } catch (e) {
      AppLog.error('cold restore tunnel init failed', e);
      return;
    }
    if (sessionEpoch != _sessionEpoch ||
        (snap.phase != ConnPhase.idle && snap.phase != ConnPhase.working)) {
      return;
    }
    if (snap.dial != null || _mutex.isLocked) return;
    // The plugin stage is a process-local static that resets on every engine
    // re-attach, and a fresh backend reports no running tunnels even when the
    // OS TUN survived — so a lone down/terminal read is not trustworthy
    // (observed: key icon up + keepalives flowing while native logged
    // `Running tunnels after reopen: []`). Null (wedged IPC) is retried
    // briefly; anything else is decided below, never trusted blindly.
    VpnStage? stage;
    for (var attempt = 0; attempt < 3; attempt++) {
      stage = await _tunnel.readStage();
      if (stage != null) break;
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (sessionEpoch != _sessionEpoch) return;
    final read = stage;
    if (read == null) {
      final cached = await _readCachedDial(id);
      if (sessionEpoch != _sessionEpoch) return;
      if (cached == null) {
        AppLog.info('cold restore stage unknown, no cache -> idle');
        return;
      }
      AppLog.info('cold restore stage unknown, cache present -> confirm');
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Restoring connection…',
      );
      await _restoreColdSession(
        id,
        VpnStage.noConnection,
        expectedSession: sessionEpoch,
      );
      return;
    }
    if (read == VpnStage.connected ||
        read == VpnStage.noConnection ||
        isColdTransitionalStage(read)) {
      await _restoreColdSession(id, read, expectedSession: sessionEpoch);
      return;
    }
    // Down/terminal stage with a previous session on disk: the stage may be
    // the fresh-backend lie described above, so server truth (`GET …/config`
    // inside [_restoreColdSession]) decides. No cache means a true fresh
    // install or an explicit teardown: stay idle without touching the
    // network. A truthful-down tunnel restored optimistically here is
    // corrected by the existing watchdogs (stage stream via [_noteStage],
    // health ticks) once the confirm succeeds.
    final cached = await _readCachedDial(id);
    if (sessionEpoch != _sessionEpoch) return;
    if (cached == null) {
      AppLog.info('cold restore stage=${read.name}, no cache -> idle');
      return;
    }
    AppLog.info(
      'cold restore stage=${read.name} disagrees with cache '
      '-> server truth decides',
    );
    snap = snap.copyWith(
      phase: ConnPhase.working,
      message: 'Restoring connection…',
      lastStage: read,
    );
    await _restoreColdSession(id, read, expectedSession: sessionEpoch);
  }

  /// Lock-free cold-restore body: caller must NOT hold [_mutex] (see
  /// [reconcileColdStart] and the stage-watch handover in [_noteStage]).
  Future<void> _restoreColdSession(
    String id,
    VpnStage stage, {
    int? expectedSession,
  }) async {
    final release = await _mutex.acquire('cold-restore');
    final sessionEpoch = expectedSession ?? _sessionEpoch;
    try {
      if (sessionEpoch != _sessionEpoch ||
          (snap.phase != ConnPhase.idle && snap.phase != ConnPhase.working)) {
        return;
      }
      if (snap.dial != null) return;
      // Restore the persisted pin first so the Regions tab and the
      // auto-pin fallback below compare against user intent.
      try {
        final saved = await _device.lastTarget();
        if ((saved.serverId != null || saved.regionId != null) &&
            snap.regionId == null &&
            snap.serverId == null) {
          snap = snap.copyWith(
            regionId: saved.regionId,
            serverId: saved.serverId,
            explicitTarget: saved.explicitTarget,
          );
        }
      } catch (e) {
        AppLog.error('cold restore saved target read failed', e);
      }
      if (sessionEpoch != _sessionEpoch) return;
      final transitional = isColdTransitionalStage(stage);
      DialParams? cached;
      // True when the read says the OS tunnel is already gone: a cold
      // restore from this branch must corroborate liveness before showing
      // Connected, or a killed-then-reopened app shows Connected for a dead
      // tunnel (fixed by auto-heal minutes later).
      final downRead =
          stage == VpnStage.disconnected ||
          stage == VpnStage.disconnecting ||
          stage == VpnStage.denied ||
          stage == VpnStage.exiting;
      if (!transitional) {
        cached = await _readCachedDial(id);
        if (sessionEpoch != _sessionEpoch) return;
        if (cached != null && !downRead) {
          // Optimistic Connected: the tunnel is up and the label is fresh
          // enough to show while server truth is confirmed below. Polling
          // restarts now so the existing health machinery corroborates or
          // degrades from here like any warm session.
          snap = snap.copyWith(
            phase: ConnPhase.connected,
            dial: cached,
            message: 'Connected',
            lastStage: stage,
            healthNote: null,
            backendIssue: null,
          );
          _resetLocalHealth();
          // Anchor the never-handshook branch of the handshake policy: a
          // restored tunnel that never completes a handshake is dead, while
          // a slow first handshake must not heal.
          _connectedAt = _clock.now();
          _startPolling();
        } else if (cached != null) {
          // Down/terminal read: stay working while server truth decides —
          // the confirm below either corroborates liveness (fresh-backend
          // lie) or tears down to idle. Showing Connected here would lie
          // until the health ticks catch up (~3min with no handshake
          // reader); showing idle would orphan a live tunnel. Polling
          // starts only after the confirm promotes to connected.
          snap = snap.copyWith(
            phase: ConnPhase.working,
            dial: cached,
            message: 'Verifying VPN status…',
            lastStage: stage,
            healthNote: _externalStopVerifyingNote,
            backendIssue: null,
          );
          _resetLocalHealth();
          _connectedAt = _clock.now();
        } else {
          // Tunnel up but nothing to label it with while offline: stay
          // usable instead of trapping the user behind a spinner; the
          // confirm below (or a later tap) fills in the label.
          snap = snap.copyWith(
            phase: ConnPhase.idle,
            message: 'VPN may still be active. Tap Connect to reconcile.',
            lastStage: stage,
          );
        }
      } else {
        snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Restoring connection…',
          lastStage: stage,
        );
      }
      DialParams dial;
      var rebound = false;
      try {
        final reconciled = await _configReconciled(
          id,
          sessionEpoch: sessionEpoch,
        );
        if (sessionEpoch != _sessionEpoch) return;
        dial = reconciled.dial;
        rebound = reconciled.rebound;
      } on DioException catch (e) {
        final kind = asVpnError(e)?.kind;
        if (kind == ApiErrorKind.notFound ||
            kind == ApiErrorKind.noActivePeer) {
          // Stale OS tunnel: the peer was GC'd/revoked while the app was
          // dead. Stop it so no ghost tunnel lingers, then idle — the next
          // Connect binds a fresh peer. The plain stop is a no-op after a
          // re-attach (`Running tunnels: []`), so the ghost-kill downs the
          // owning backend directly. The device itself is kept for a fresh
          // bind (cleared only on true 404 below).
          AppLog.info('cold restore $kind -> stop stale tunnel');
          await _stopTunnel('cold-start-stale');
          if (sessionEpoch != _sessionEpoch) return;
          if (kind == ApiErrorKind.notFound) {
            try {
              await _wipeDevice();
            } catch (e) {
              AppLog.error('cold restore clear device failed', e);
            }
            if (sessionEpoch != _sessionEpoch) return;
          } else {
            // Peerless: the device is kept for a fresh bind, but the cached
            // dial points at the peer the server just reported gone — drop
            // it so the next offline cold start can't optimistically restore
            // or sit verifying that dead session.
            await _clearCachedDial();
            if (sessionEpoch != _sessionEpoch) return;
          }
          _stopPolling();
          _resetLocalHealth();
          _coldRestore.armed = false;
          _idleAfterDeviceGone(
            message: kind == ApiErrorKind.notFound
                ? 'Device was removed. Connect again to reprovision.'
                : 'Session expired. Tap Connect to reconnect.',
          );
          return;
        }
        // Offline (or app error): keep the optimistic/working state and
        // watch the stage stream — a later `connected` event retries the
        // confirm, a terminal event falls back to idle (see [_noteStage]).
        AppLog.error('cold restore confirm failed', e);
        _coldRestore.armed = true;
        return;
      } catch (e) {
        if (sessionEpoch != _sessionEpoch) return;
        AppLog.error('cold restore confirm failed', e);
        _coldRestore.armed = true;
        return;
      }
      // Server truth wins: replace the optimistic dial, refresh the cache.
      try {
        await _device.setLastDialJson(jsonEncode(dial.toJson()));
      } catch (e) {
        AppLog.error('cold restore persist dial failed', e);
      }
      if (sessionEpoch != _sessionEpoch) return;
      // An unpinned (Auto) state stays unpinned here: the restored dial
      // labels the session while the pin remains empty, so later connects
      // re-pick fresh instead of sticking to the restored server.
      if (downRead || rebound) {
        // Down-read confirm (`GET …/config` ok) or a key rebind: the peer
        // exists server-side but any surviving OS tunnel runs a stale key.
        // Always bounce (stop, then start on the server-confirmed dial):
        // after a process/engine death this process
        // never owns the surviving TUN (fresh backend reports
        // `Running tunnels: []`), so adopting it leaves a handle-less ghost
        // that later disconnects can't kill (it keeps handshaking after
        // `Device closed`). A new `establish()` replaces whatever the OS
        // read lied about and gives this backend ownership, so the normal
        // machinery verifies from there. Only corroborated-dead evidence
        // tears down to idle instead; a rebind never does (the peer is
        // confirmed, only its key changed).
        final alive = rebound ? null : await _coldRestoreAlive(dial);
        if (sessionEpoch != _sessionEpoch) return;
        if (!rebound && alive == false) {
          AppLog.info(
            'cold restore down-read corroborated dead -> ghost-kill + idle',
          );
          await _stopTunnel('cold-start-dead');
          if (sessionEpoch != _sessionEpoch) return;
          _stopPolling();
          _resetLocalHealth();
          _coldRestore.clear();
          snap = _resetSessionCounters(
            snap.copyWith(
              phase: ConnPhase.idle,
              dial: null,
              deviceStatus: null,
              lastStatusAt: null,
              message: 'VPN stopped outside the app',
              lastStage: VpnStage.disconnected,
              healthNote: null,
              backendIssue: null,
            ),
          );
          return;
        }
        AppLog.info(
          rebound
              ? 'cold restore rebound -> bounce on the fresh key'
              : 'cold restore down-read -> bounce on the server-confirmed dial '
                    '(alive=${alive == true ? 'likely' : 'unknown'})',
        );
        snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Restoring connection…',
        );
        await _stopTunnel(
          rebound ? 'cold-restore-rebind' : 'cold-restore-bounce',
        );
        if (sessionEpoch != _sessionEpoch) return;
        try {
          await _startWith(dial, sessionEpoch: sessionEpoch);
          if (sessionEpoch != _sessionEpoch) return;
        } catch (e) {
          if (sessionEpoch != _sessionEpoch) return;
          final vpnErr = asVpnError(e);
          AppLog.error('cold restore restart failed', vpnErr?.message ?? e);
          snap = snap.copyWith(
            phase: ConnPhase.error,
            message:
                'Could not restore the VPN '
                '(${vpnErr?.message ?? e}). Tap Connect.',
            lastStage: null,
          );
        }
        return;
      }
      if (sessionEpoch != _sessionEpoch) return;
      _promoteColdRestore(dial, verified: false);
    } finally {
      release();
    }
  }

  /// Promotes a server-truth-confirmed cold restore to Connected.
  ///
  /// [verified] marks a down-read restore whose liveness was positively
  /// corroborated ([_coldRestoreAlive]): the stage stream will replay the
  /// fresh-backend `disconnected` lie right after, so the post-restore
  /// grace stays anchored. Up-read restores keep the previous behavior
  /// (no grace — the OS already reported the tunnel alive).
  void _promoteColdRestore(DialParams dial, {required bool verified}) {
    snap = _resetSessionCounters(
      snap.copyWith(
        phase: ConnPhase.connected,
        dial: dial,
        message: 'Connected',
        lastStage: VpnStage.connected,
        healthNote: null,
        backendIssue: null,
      ),
    );
    _coldRestore.armed = false;
    _resetLocalHealth();
    _connectedAt = _clock.now();
    // Anchor the post-restore grace: the stage stream replays the
    // fresh-backend `disconnected` lie right after this confirm.
    _coldRestore.confirmedAt = verified ? _clock.now() : null;
    _startPolling();
    AppLog.info(
      'cold restore ok server=${dial.serverName}${verified ? ' (verified)' : ''}',
    );
  }

  /// Local liveness for a down-read cold restore whose server peer exists:
  /// true = tunnel likely alive (fresh-backend lie), false = corroborated
  /// dead, null = unknown. The caller bounces on anything but false (see
  /// [_restoreColdSession]): after a process death every local reader is
  /// structurally blind — the stage says down while
  /// traffic/handshake/gateway cannot observe a tunnel this process never
  /// started — and even a "likely alive" tunnel is handle-less here, so
  /// adopting it would leave a ghost no later disconnect can kill.
  Future<bool?> _coldRestoreAlive(DialParams dial) async {
    try {
      // Strongest signal: the live native peer already is the
      // server-confirmed dial (same server key on the same endpoint) — the
      // data path is correct, adopt silently without a bounce.
      final live = await _livePeer();
      if (live != null && _livePeerMatches(dial, live)) return true;
      final restage = await _tunnel.readStage();
      if (restage != null &&
          (restage == VpnStage.connected ||
              _isDegradedStage(restage) ||
              isColdTransitionalStage(restage))) {
        return true;
      }
      // Traffic counters prove the OS tunnel object is alive and passing
      // bytes: on a live restore the plugin answers immediately (see the
      // `VPN active on trafficEvent listen: true` log line), while a dead
      // tunnel's read fails/times out. Displayed on the Home card anyway,
      // so publish them when they prove liveness.
      try {
        final traffic = await _tunnel.readTraffic();
        final rx = traffic == null ? null : extractRxBytes(traffic);
        final tx = traffic == null ? null : extractTxBytes(traffic);
        if (rx != null || tx != null) {
          snap = snap.copyWith(
            rxBytes: rx ?? snap.rxBytes,
            txBytes: tx ?? snap.txBytes,
          );
          return true;
        }
      } catch (e) {
        AppLog.error('cold restore traffic read failed', e);
      }
      final now = _clock.now();
      final handshake = await _readHandshake();
      if (handshake != null &&
          !isHandshakeStale(
            lastHandshakeAt: handshake,
            now: now,
            connectedAt: _connectedAt,
          )) {
        return true;
      }
      // Tri-state, never throws (see [ConnectionHealth._gatewayAlive]).
      final gateway = await _gatewayAlive(dial.wgDns);
      if (gateway == true) return true;
      final restageTerminal =
          restage == VpnStage.disconnected ||
          restage == VpnStage.disconnecting ||
          restage == VpnStage.denied ||
          restage == VpnStage.exiting;
      final handshakeStaleConfirmed = isHandshakeStale(
        lastHandshakeAt: handshake,
        now: now,
        // A cold-anchored `_connectedAt` must not count as fresh here: it
        // was set minutes after the tunnel died (see
        // [_unknownHandshakeIsColdAnchored]). Full null window, same
        // reasoning as [_corroborateExternalStop].
        connectedAt: _unknownHandshakeIsColdAnchored(now)
            ? now.subtract(ConnectionTuning.handshakeStaleAfter)
            : _connectedAt,
        graceAfter: ConnectionTuning.handshakeStaleAfter,
      );
      if (restageTerminal && handshakeStaleConfirmed && gateway == false) {
        return false;
      }
      return null;
    } catch (e) {
      AppLog.error('cold restore liveness check failed', e);
      return null;
    }
  }

  /// Cached dial for the optimistic restore, or null when absent,
  /// unreadable, or belonging to another device (stale after reprovision).
  /// Never throws.
  Future<DialParams?> _readCachedDial(String deviceId) async {
    try {
      final raw = await _device.lastDialJson();
      if (raw == null || raw.isEmpty) return null;
      final dial = DialParams.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (dial.deviceId != deviceId) return null;
      return dial;
    } catch (e) {
      AppLog.error('cold restore cached dial read failed', e);
      return null;
    }
  }

  /// Live peer behind the native tunnel, or null when unknown/none. Never
  /// throws (see [TunnelAdapter.getActivePeer]).
  Future<ActivePeer?> _livePeer() async {
    final seam = debugActivePeer;
    if (seam != null) return seam;
    return _tunnel.getActivePeer();
  }

  /// True when the live native peer is the server-confirmed [dial]: same
  /// server public key on the same endpoint. Reported to
  /// [_coldRestoreAlive] as likely-alive evidence; the down-read caller
  /// still bounces to regain backend ownership of the TUN.
  bool _livePeerMatches(DialParams dial, ActivePeer live) {
    if (live.publicKey.trim().isEmpty) return false;
    if (live.publicKey.trim() != dial.wgPublicKey.trim()) return false;
    return live.endpoint.trim() == formatEndpoint(dial.endpoint, dial.wgPort);
  }
}
