part of 'connection_controller.dart';

extension ConnectionTunnel on ConnectionController {
  /// Drops the cached local health anchors (tunnel start + traffic
  /// counters) whenever the tunnel is no longer the one they describe.
  void _resetLocalHealth() {
    _connectedAt = null;
    _lastStatusAnswered = false;
    // A new tunnel generation re-earns its dead-echo strikes (see
    // [ConnectionTuning.echoStallStrikes]); a dead server will re-confirm
    // within a few ticks, while a recovered tunnel is never pre-charged.
    _deadEchoStrikes = 0;
    if (snap.rxBytes != null || snap.txBytes != null) {
      snap = snap.copyWith(rxBytes: null, txBytes: null);
    }
  }

  Future<void> _ensureTunnelInit() async {
    await _tunnel.ensureInitialized();
    if (_stageSub != null) return;
    // OS-side stops are reflected via [_noteStage] corroboration (a lone
    // `disconnected` never tears down directly — server truth decides), so
    // the UI doesn't stay stuck on "Connected" yet never kills a live
    // tunnel on a stale event. App state stays authoritative for every
    // other stage; degraded stages only set a banner.
    try {
      _stageSub = _tunnel.stages.listen(
        _noteStage,
        onError: (Object e) => AppLog.error('tunnel stage stream failed', e),
      );
    } catch (e) {
      // Event channel unavailable on this platform; ignore.
      AppLog.error('tunnel stage subscription unavailable', e);
    }
  }

  /// (Re)starts the background status poll. Only the connected tunnel
  /// needs it: every other phase stops it (disconnect/reset/suspend).
  /// Steady interval stays >= 60s against the session-budgeted
  /// `status_limiter`; [PollingService] additionally fires one early check
  /// (~12s) per (re)connect so a dead server is corroborated without
  /// waiting out a full interval. The local health check below is
  /// backend-free and may run faster.
  ///
  /// [earlyStatus] defaults to "only when foreground": a background
  /// (re)start skips the early check, which would otherwise add a wakeup
  /// and race the resume catch-up. Lifecycle restarts pass false
  /// explicitly.
  void _startPolling({bool? earlyStatus}) {
    _polling.start(
      onStatus: pollStatusOnce,
      onHealth: checkHealthOnce,
      background: _backgrounded,
      earlyStatus: earlyStatus ?? !_backgrounded,
    );
  }

  void _stopPolling() {
    _polling.stop();
  }

  /// Graceful tunnel teardown via [TunnelAdapter.stop] (graceful attempt
  /// plus one automated hard-kill retry, never throws), followed by a
  /// best-effort native ghost-kill that downs the owning backend directly —
  /// after an engine restart the plugin lost its handle (`Running tunnels:
  /// []`) while the OS `VpnService` keeps handshaking, and the plain stop is
  /// a no-op there. Bumps the tunnel epoch first so in-flight status
  /// polls resolve as superseded instead of blaming the backend. The epoch
  /// doubles as the tunnel generation in logs: native GoBackend lines carry
  /// no generation, so a late flush from the previous device can otherwise
  /// masquerade as a handshake failure on the live tunnel.
  Future<void> _stopTunnel(String reason) async {
    _tunnelEpoch++;
    final gen = _tunnelEpoch;
    AppLog.info('tunnel stop ($reason) gen=$gen');
    await _tunnel.stop(reason);
    // Best-effort: no-op when nothing survives, real DOWN when a ghost does.
    // Never throws (see [TunnelAdapter.killGhost]).
    await _tunnel.killGhost();
    AppLog.info('tunnel stopped ($reason) gen=$gen');
  }

  /// True when a handshake can actually be observed: the test seam is set, or
  /// the active adapter has a native reader (Linux/Android/Windows). Gates
  /// the never-handshook branches of [isHandshakeStale] — an unsupported
  /// reader's null is absence of evidence, never a stall.
  bool get _readerSupported =>
      debugHandshakeReader != null || _tunnel.handshakeReaderSupported;

  /// Reads the last completed handshake, honoring the test seam
  /// ([debugHandshakeReader]) and the adapter's short health timeout.
  /// Failures resolve as null (unknown, never a stall on its own).
  Future<DateTime?> _readHandshake() async {
    final seam = debugHandshakeReader;
    try {
      if (seam != null) {
        return await seam().timeout(TunnelTuning.healthTimeout);
      }
      return await _tunnel.readHandshake();
    } catch (e) {
      AppLog.error('handshake read failed', e);
      return null;
    }
  }

  Future<void> _startWith(
    DialParams dial, {
    bool preservePollFailures = false,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) return;

    // Validate the Apple Network-Extension build config before touching the
    // live tunnel, so a missing define fails fast here rather than after the
    // working tunnel has already been stopped. `bundleId` is what `startVpn`
    // needs; the App Group is checked for the same reason even though
    // `ensureInitialized` resolves it too — a connect must name the actual
    // missing define, not a later plugin failure.
    final bundleId = resolveProviderBundleId();
    resolveAppGroup();
    AppLog.info(
      'tunnel start gen=$_tunnelEpoch device=${AppLog.redact(dial.deviceId)} '
      'server=${dial.serverName} ${dial.endpoint}:${dial.wgPort}',
    );
    final priv = await _device.privateKey();
    if (!sessionCurrent()) return;
    if (priv == null) throw StateError('Missing private key. Reprovision.');
    // Server-reported active peer key (when the backend supplies it) must
    // match the keypair the conf is built from: a mismatch means a stale local
    // identity would start a tunnel the server can never handshake. The
    // network paths reconcile via [_configReconciled] first, so this is the
    // last-line guard for any path that skipped it.
    final serverClientKey = dial.clientPublicKey;
    if (serverClientKey != null && serverClientKey.isNotEmpty) {
      final localPub = await _device.publicKey();
      if (!sessionCurrent()) return;
      if (localPub != serverClientKey) {
        throw StateError(
          'Local WireGuard key no longer matches the server active peer. '
          'Reconnect to repair the identity.',
        );
      }
    }
    final allowLocal = await _device.allowLocal();
    if (!sessionCurrent()) return;
    final conf = buildWgQuickConfig(
      privateKey: priv,
      assignedIp: dial.assignedIp,
      serverPublicKey: dial.wgPublicKey,
      endpointHost: dial.endpoint,
      endpointPort: dial.wgPort,
      dns: dial.wgDns,
      allowLocal: allowLocal,
    );
    await _ensureTunnelInit();
    if (!sessionCurrent()) return;
    if (snap.phase == ConnPhase.connected) {
      // Never run two live tunnels (Windows/Wintun route wedge).
      await _stopTunnel('restart');
      if (!sessionCurrent()) return;
    }
    // Apple platforms only (see `resolveProviderBundleId`): the plugin
    // requires a non-null String and ignores it on every other OS.
    await _tunnel.start(
      serverAddress: formatEndpoint(dial.endpoint, dial.wgPort),
      wgQuickConfig: conf,
      providerBundleId: bundleId,
    );
    if (!sessionCurrent()) {
      // The auth listener can invalidate the operation while the native
      // start call is in flight. Do not leave that old tunnel running; the
      // serialized revocation cleanup will also clear its device identity.
      await _stopTunnel('session-invalidated');
      return;
    }
    AppLog.info(
      'tunnel connected gen=$_tunnelEpoch device=${AppLog.redact(dial.deviceId)} '
      'server=${dial.serverName}',
    );
    // Fresh tunnel, fresh evidence — except the auto-heal paths below,
    // which preserve the in-tunnel failures so one outage doesn't need a
    // full new set of 60s polls after every restart.
    final pollFailures = preservePollFailures ? snap.pollFailures : 0;
    // Any fresh tunnel start supersedes cold watching and its grace.
    _coldRestore.clear();
    snap = snap.copyWith(
      phase: ConnPhase.connected,
      dial: dial,
      message: 'Connected',
      pollFailures: pollFailures,
      lastStage: VpnStage.connected,
      healthNote: null,
      backendIssue: null,
      autoHealAttempts: 0,
      autoFailoverAttempts: 0,
      rxBytes: null,
      txBytes: null,
    );
    // No pinned target yet (Auto): stay unpinned so later connects
    // re-pick fresh. The Regions tab marks only the Quick Connect row for
    // Auto — no server is highlighted until explicitly pinned — and
    // reconnect stickiness for explicit pins comes from their own
    // `selectTarget` calls — never from collapsing Auto onto the dial.
    // Cache the server truth for cold-start reconciliation (optimistic
    // Connected label while `GET …/config` is in flight). Awaited (not
    // fire-and-forget like [_persistTarget]) so the cache is durable before
    // this returns; best-effort — a storage failure must never fail a good
    // connect.
    try {
      await _device.setLastDialJson(jsonEncode(dial.toJson()));
    } catch (e) {
      AppLog.error('persist dial failed', e);
    }
    if (!sessionCurrent()) {
      await _stopTunnel('session-invalidated');
      snap = const ConnState(message: 'Session ended. Please log in again.');
      return;
    }
    _resetLocalHealth();
    // Anchor the never-handshook branch of the handshake policy (see
    // [_connectedAt]): a fresh tunnel gets at least the grace window
    // before a null read can count (a full stale window on the
    // verification paths; unsupported readers never count).
    _connectedAt = _clock.now();
    _startPolling();
  }

  /// One-line budget snapshot for heal/failover start logs: how many
  /// same-server heals and moves are spent, how many status polls failed,
  /// and how long ago a poll last proved the backend reachable
  /// (`never-polled` when no success yet this session).
  String _healBudgets() {
    final at = snap.lastStatusAt;
    final quiet = at == null
        ? 'never-polled'
        : '${_clock.now().difference(at).inSeconds}s';
    return 'gen=$_tunnelEpoch heals=${snap.autoHealAttempts} '
        'failovers=${snap.autoFailoverAttempts} '
        'pollFailures=${snap.pollFailures} '
        'backendQuiet=$quiet';
  }

  /// Stages that mean the OS tunnel is alive but not passing traffic.
  /// Delegates to [isDegradedStage] (pure policy in `domain/`).
  bool _isDegradedStage(VpnStage s) => isDegradedStage(s);
}
