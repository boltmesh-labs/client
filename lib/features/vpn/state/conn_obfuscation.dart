part of 'connection_controller.dart';

/// The transport ladder.
///
/// The serving node advertises which rungs it runs, in cost order (see
/// `TransportOption`), and where the walk *starts* is the cheapest rung on that
/// list this platform can run (see [_rungFor]). So a node serving both stock and
/// obfuscated starts stock and demotes, rather than being treated as a
/// single-format node with one option — and a node that serves only `awg` and
/// `stream` floors a platform with no obfuscated data plane to `stream` rather
/// than refusing it.
///
/// The demotion rides the existing heal rung — [_autoHeal] already restarts the
/// cached config offline, which is exactly the moment a fingerprint-blocked path
/// should be retried on a lower rung. It is licensed by local path-death
/// evidence alone, not the control plane: in a full tunnel the probe is routed
/// through the very rung that is dead, so requiring it made the step
/// unreachable exactly when it is needed. It costs no polling timer and no
/// budget of its own: [ConnectionTuning.maxHealsPerIncident] is what bounds the
/// walk. After a long healthy period, the health tick may
/// probe one cheaper rung; the last known-working rung remains the rollback
/// target until the candidate proves live.
extension ConnectionObfuscation on ConnectionController {
  /// The rung this process is on. Demotions stay sticky across connects to
  /// avoid re-paying for a failed path. The health tick may probe one cheaper
  /// rung after [ConnectionTuning.rungPromotionHealthyFor]; it returns to the
  /// known-working rung if liveness is not confirmed within
  /// [ConnectionTuning.rungPromotionProbeTimeout]. A server move also moves the
  /// rung to the new node's floor, or to the highest rung that node advertises.
  TransportRung get transportRung => _transportRung;

  /// The obfuscation parameters to build a conf for [dial] with, or null when
  /// this start's tunnel is stock WireGuard.
  ///
  /// Only the obfuscated rung carries them, because it is the only one pointed at
  /// the node's obfuscated device — and only that entry has a `params` field at
  /// all. The other two are stock: the native rung by definition, and the stream
  /// rung because the node's bridge injects into its *stock* device whatever else
  /// that node serves, so a stream session carries stock datagrams inside its TLS
  /// session.
  ObfuscationParams? _obfuscationParamsFor(DialParams dial) =>
      _transportFor(dial).params;

  /// The advertised entry for the rung this start is on.
  ///
  /// The one place a rung's advertisement is read, so the port, the parameters
  /// and the credential used to build a start can never come from a rung other
  /// than the one being started. Non-null by construction: [_applyRung] has
  /// already refused a rung this node does not advertise or this build cannot
  /// assemble, and nothing between it and here changes the rung.
  TransportOption _transportFor(DialParams dial) =>
      dial.transportFor(_transportRung)!;

  /// The node's own port for the rung this start is on.
  ///
  /// The rung's advertised port, which is that rung's own device: the node runs a
  /// separate device per transport, so a stock device cannot read obfuscation
  /// directives and an obfuscated device cannot read a stock handshake, and
  /// neither port is interchangeable with the other in either direction.
  int _tunnelPortFor(DialParams dial) => _transportFor(dial).port;

  /// The overlay address this start must claim.
  ///
  /// The node has one network per device, so the address follows the rung rather
  /// than the server: the obfuscated device routes only the addresses its own
  /// overlay contains, and a stock address sent there handshakes fine and then
  /// blackholes every packet — which reads as a blocked network and demotes the
  /// rung that was working.
  ///
  /// Only the obfuscated rung has a second address, and it is exactly the case
  /// [_awgRungRunnable] gates on, so there is nothing to fall back to here. The
  /// stream rung is stock because the node's bridge injects into its *stock*
  /// device: a stream session carries stock WireGuard datagrams whatever else
  /// that node serves, and handing those to the obfuscated device is a handshake
  /// into a void.
  String _overlayAddressFor(DialParams dial) =>
      _transportRung == TransportRung.awg
      ? dial.awgAssignedIp!
      : dial.assignedIp;

  /// The in-tunnel resolver for this start.
  ///
  /// Same rule as the address: the node runs one systemd-resolved stub per
  /// interface, so the resolver has to be the one on the device this start's
  /// traffic reaches. Pushing the stock stub's address onto the obfuscated rung
  /// would send every DNS query to a device with no route for it.
  String _overlayDnsFor(DialParams dial) =>
      _transportRung == TransportRung.awg ? dial.awgDns! : dial.wgDns;

  /// Whether the obfuscated rung is something this start could actually build.
  ///
  /// The advertised entry carries the port and the parameter set; what it cannot
  /// carry is the *peer's* address on the obfuscated overlay, because that belongs
  /// to the device and is the same for every session. A rung without one is a
  /// conf whose every packet the node's second device cannot route — a tunnel
  /// that handshakes and then goes nowhere, which reads to the health ladder as a
  /// blocked network and demotes the rung that was working. So the rung counts as
  /// not offered rather than offered and broken, which is what the control
  /// plane's withholding on its own side is for.
  /// Both fields, because the pair is emitted together or not at all (see the
  /// backend factory) — checking one and then asserting the other would be a
  /// check of an invariant, not of input.
  bool _awgRungRunnable(DialParams dial) =>
      dial.transportFor(TransportRung.awg) != null &&
      (dial.awgAssignedIp?.isNotEmpty ?? false) &&
      (dial.awgDns?.isNotEmpty ?? false);

  /// The stream transport for this start, or null unless this process is on the
  /// stream rung.
  ///
  /// Total by construction now: [_rungRunnableHere] is what admits the stream
  /// rung onto the ladder, and it requires both a usable credential from the
  /// advertised entry and a data plane that can run it. So there is nothing left
  /// to check here — every value below is the one that gate accepted, and the
  /// rung below can neither be silently substituted nor invented.
  Future<TunnelTransport?> _streamTransportFor(DialParams dial) async {
    if (_transportRung != TransportRung.stream) return null;
    final credential = _transportFor(dial).credential!;
    final ports = await allocateLoopbackPorts();
    return TunnelTransport(
      listen: '${TunnelTransport.loopbackHost}:${ports.listen}',
      deliver: '${TunnelTransport.loopbackHost}:${ports.deliver}',
      credential: credential,
    );
  }

  /// Moves the process one rung down when [dial]'s node advertises one below.
  /// Idempotent: a process already on the last advertised rung reports false, so
  /// the heal that demotes is also the only one that can.
  ///
  /// The walk is one rung per heal and never skips: with the advertised list
  /// there is no cheaper rung *unless the node says it runs one*, and the rung
  /// below is by definition the one the rung above has not disproved yet. How
  /// many steps an incident gets is [ConnectionTuning.maxHealsPerIncident]'s
  /// business, not this method's — a node serving two rungs below the floor is
  /// walked to the bottom of its own list, and one rung below gets exactly one
  /// step.
  ///
  /// [why] is the health reason that triggered the heal, so the log names the
  /// evidence the demotion acted on.
  bool _demoteRung(DialParams dial, String why) {
    final next = _nextRungFor(dial);
    if (next == null) return false;
    AppLog.info(
      'transport demoted ($why) ${_transportRung.name} -> ${next.name}',
    );
    _transportRung = next;
    return true;
  }

  /// The rung immediately above the current one on [dial]'s ladder, or null at
  /// the floor.
  ///
  /// Read off the advertised list rather than the process-wide cost order, so the
  /// candidate is always a rung the serving node really offers. That is also what
  /// makes the probe structurally non-trivial: every entry in the list carries the
  /// port and payload its own rung needs, so the rung below can never build the
  /// same conf as the one above it.
  TransportRung? _cheaperRungFor(DialParams dial) {
    final rungs = _runnableRungs(dial);
    final at = rungs.indexOf(_transportRung);
    // Index 0 is the floor, so nothing cheaper exists below it; a negative index
    // means the current rung is not advertised at all, which [_applyRung] rejects
    // before any start.
    if (at <= 0) return null;
    return rungs[at - 1];
  }

  /// Probe one cheaper rung after a long, positively healthy session. The
  /// previous rung stays armed until a fresh handshake or live gateway echo
  /// confirms the candidate; a failed start rolls back immediately, while a
  /// silent/dead candidate rolls back through the normal heal path.
  Future<void> _maybeProbeCheaperRung(
    DialParams dial, {
    required bool pathHealthy,
  }) async {
    if (!pathHealthy ||
        _promotionFallbackRung != null ||
        snap.phase != ConnPhase.connected ||
        !identical(snap.dial, dial) ||
        !canAttemptAutoHeal(
          autoHealAttempts: snap.autoHealAttempts,
          autoFailoverAttempts: snap.autoFailoverAttempts,
          maxFailovers: ConnectionTuning.maxAutoFailovers,
          maxHealsPerIncident: ConnectionTuning.maxHealsPerIncident,
          maxHealsAfterMoveBudget: ConnectionTuning.maxHealsAfterMoveBudget,
        )) {
      return;
    }
    final connectedAt = _connectedAt;
    if (connectedAt == null ||
        _clock.now().difference(connectedAt) <
            ConnectionTuning.rungPromotionHealthyFor) {
      return;
    }
    final candidate = _cheaperRungFor(dial);
    if (candidate == null) return;

    final release = await _mutex.acquire('transport-promotion');
    try {
      final currentConnectedAt = _connectedAt;
      if (snap.phase != ConnPhase.connected ||
          !identical(snap.dial, dial) ||
          _promotionFallbackRung != null ||
          !canAttemptAutoHeal(
            autoHealAttempts: snap.autoHealAttempts,
            autoFailoverAttempts: snap.autoFailoverAttempts,
            maxFailovers: ConnectionTuning.maxAutoFailovers,
            maxHealsPerIncident: ConnectionTuning.maxHealsPerIncident,
            maxHealsAfterMoveBudget: ConnectionTuning.maxHealsAfterMoveBudget,
          ) ||
          currentConnectedAt == null ||
          _clock.now().difference(currentConnectedAt) <
              ConnectionTuning.rungPromotionHealthyFor ||
          _cheaperRungFor(dial) != candidate) {
        return;
      }

      final sessionEpoch = _sessionEpoch;
      final previousRung = _transportRung;
      final previousHealAttempts = snap.autoHealAttempts;
      final previousFailoverAttempts = snap.autoFailoverAttempts;
      final previousPollFailures = snap.pollFailures;
      _promotionFallbackRung = previousRung;
      _promotionFallbackDial = dial;
      _transportRung = candidate;
      final recoveryAction = switch (candidate) {
        TransportRung.native => RecoveryAction.tryingNative,
        TransportRung.awg => RecoveryAction.tryingAwg,
        TransportRung.stream => RecoveryAction.tryingStream,
      };
      AppLog.info(
        'transport promotion probe ${previousRung.name} -> ${candidate.name} '
        'server=${dial.serverName}',
      );
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Reconnecting…',
        recoveryAction: recoveryAction,
        recoveryReason: RecoveryReason.stableSessionProbe,
        recoveryDetail: '${previousRung.name} -> ${candidate.name}',
      );
      await _stopTunnel('transport-promotion');
      if (sessionEpoch != _sessionEpoch) {
        _promotionFallbackRung = null;
        _promotionFallbackDial = null;
        return;
      }
      try {
        await _startWith(
          dial,
          preservePollFailures: true,
          sessionEpoch: sessionEpoch,
        );
        if (sessionEpoch != _sessionEpoch) {
          _promotionFallbackRung = null;
          _promotionFallbackDial = null;
          return;
        }
        snap = snap.copyWith(
          autoHealAttempts: previousHealAttempts,
          autoFailoverAttempts: previousFailoverAttempts,
          pollFailures: previousPollFailures,
        );
      } catch (e) {
        if (sessionEpoch != _sessionEpoch) return;
        AppLog.error('cheaper transport probe failed to start', e);
        _transportRung = previousRung;
        _promotionFallbackRung = null;
        _promotionFallbackDial = null;
        snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Reconnecting…',
          recoveryAction: RecoveryAction.restarting,
          recoveryReason: RecoveryReason.cheaperTransportUnresponsive,
          recoveryDetail: e.toString(),
        );
        try {
          await _startWith(
            dial,
            preservePollFailures: true,
            sessionEpoch: sessionEpoch,
          );
          if (sessionEpoch != _sessionEpoch) {
            _promotionFallbackRung = null;
            _promotionFallbackDial = null;
            return;
          }
          snap = snap.copyWith(
            autoHealAttempts: previousHealAttempts,
            autoFailoverAttempts: previousFailoverAttempts,
            pollFailures: previousPollFailures,
          );
          AppLog.info(
            'transport promotion rolled back to ${previousRung.name}',
          );
        } catch (fallbackError) {
          if (sessionEpoch != _sessionEpoch) return;
          final vpnErr = asVpnError(fallbackError);
          AppLog.error(
            'known-good transport restart failed',
            vpnErr ?? fallbackError,
          );
          _stopPolling();
          _resetLocalHealth();
          snap = snap.copyWith(
            phase: ConnPhase.error,
            message:
                'VPN reconnect failed (${failureReason(vpnErr, fallbackError)}). Tap Connect.',
            lastStage: null,
            healthNote: null,
            backendIssue: null,
          );
        }
      }
    } finally {
      release();
    }
  }

  void _confirmTransportPromotion() {
    final previous = _promotionFallbackRung;
    if (previous == null) return;
    AppLog.info(
      'transport promotion confirmed ${previous.name} -> ${_transportRung.name}',
    );
    _promotionFallbackRung = null;
    _promotionFallbackDial = null;
  }

  /// The rung one step below the current one that [dial]'s node actually
  /// advertises, or null when there is nothing below to walk onto.
  ///
  /// The next entry in the advertised list, not the next value in the cost order:
  /// a node that serves only stock and stream must demote straight to stream, and
  /// one whose awg entry this platform cannot run must skip it. Reading the list
  /// is what makes both work without a per-server special case.
  ///
  /// Split out of [_demoteRung] so the health tick can ask whether a heal
  /// would lower the rung *before* spending one, without mutating it: the
  /// ladder is only worth a restart when there is a rung underneath it.
  TransportRung? _nextRungFor(DialParams dial) {
    final rungs = _runnableRungs(dial);
    final at = rungs.indexOf(_transportRung);
    if (at < 0 || at + 1 >= rungs.length) return null;
    return rungs[at + 1];
  }

  /// Whether a heal against [dial] would leave the rung lower. Pure: it reads
  /// the ladder without moving it, so a caller can gate on it and leave the
  /// ladder alone when the answer is no.
  bool _hasLowerRung(DialParams dial) => _nextRungFor(dial) != null;

  /// The rungs [dial]'s node advertises that this platform can actually start,
  /// cheapest first.
  ///
  /// The advertised list, minus what this build cannot start. Ordered by the
  /// *node*, so a walk down it is a walk down what that node really offers rather
  /// than down a fixed cost order the node may not serve — the two diverge the
  /// moment a node runs two devices and omits one, which is the case that used to
  /// be unrepresentable on the wire.
  List<TransportRung> _runnableRungs(DialParams dial) => [
    for (final rung in dial.advertisedRungs)
      if (_rungRunnableHere(dial, rung)) rung,
  ];

  /// Whether this build can start [rung] against [dial], given the node
  /// advertises it.
  ///
  /// A rung this build cannot start is not on the ladder, so it is never
  /// selected, never stepped onto, and never probed. This is the whole platform
  /// gate, and scoping it to *this dial* rather than to the rung alone is what
  /// lets the floor be a lookup: the answer differs per server (whether the node
  /// serves it) and per platform (whether it can be run), and both have to hold.
  bool _rungRunnableHere(DialParams dial, TransportRung rung) => switch (rung) {
    TransportRung.native => true,
    TransportRung.awg => awgDataPlaneSupported() && _awgRungRunnable(dial),
    // Two halves: the platform needs a bridge to run at all, and the installed
    // helper has to be one whose `up` would honour the spec. The credential's own
    // usability is already settled by `TransportOption.isComplete`.
    TransportRung.stream =>
      streamTransportSupported() &&
          _daemonCapabilities.contains(capStreamTransport),
  };

  /// The rung to start [dial] on, given the process's current one.
  ///
  /// The rule, stated exactly:
  ///
  /// > floor = the cheapest rung **the node advertises** that **this platform can
  /// > run**
  ///
  /// Not "the cheapest rung this platform can run" — that was the old derivation's
  /// blind spot, and with every node serving both formats it floors Apple to `awg`
  /// and makes the product unusable there. Scoped to the advertised list, a
  /// dual-format node floors every platform to `native`, because `native` is in the
  /// list and every platform can run it.
  ///
  /// On top of the floor, two bounds, both about the serving node rather than the
  /// network:
  ///
  ///  * Never start below it. A node serving only `awg` and `stream` floors here to
  ///    `stream`, which is the right answer rather than a refusal.
  ///  * Never keep a rung the node does not advertise. A server move can land on a
  ///    node with no stream credential, where a sticky stream rung could only throw
  ///    (see [_streamTransportFor]).
  ///
  /// The health policy's demotion survives both: this only raises to the floor and
  /// lowers to the ceiling, so a walk down the ladder is never undone. A move onto a
  /// node that *does* advertise the sticky rung leaves it alone, so a roam is not
  /// charged for the walk again.
  ///
  /// Null means the node advertises no rung this build can start — a payload with no
  /// usable entry at all, not a format this build lacks. [_applyRung] refuses rather
  /// than inventing a start the node could not read.
  TransportRung? _rungFor(DialParams dial) {
    final runnable = _runnableRungs(dial);
    if (runnable.isEmpty) return null;
    // Test seam (see [debugForceRung]): an e2e walks the whole ladder by
    // pinning each rung, which the health policy would otherwise only reach on
    // a blocked network. Still scoped to `runnable`, so it can only start a
    // rung this node serves and this build can assemble.
    final forced = debugForceRung;
    if (forced != null && runnable.contains(forced)) return forced;
    if (runnable.contains(_transportRung)) return _transportRung;
    final ceiling = runnable.last;
    final floor = runnable.first;
    if (_transportRung.index < floor.index) return floor;
    // Above the ceiling, or *between* two advertised rungs but served by neither
    // — the case an index range would read as "still inside the ladder" and start
    // on a rung the node does not serve. The ceiling is the right side of it:
    // reaching the unserved rung in the first place means the walk demoted past
    // the rungs below it, and those are the ones the network is blocking.
    return ceiling;
  }

  /// Applies [_rungFor] before a start, logging the move, and refuses a server
  /// advertising no rung this build can produce a start for.
  ///
  /// Called at the top of every [_startWith] — the one point a connect, a
  /// switch, a heal and a cold restore all pass through — so a move onto a server
  /// with a different rung list can never start on the previous server's rung, and
  /// can never start on a rung the new node does not serve.
  ///
  /// Refusing is the point, and now it means one narrow thing: there is no entry
  /// here to build a conf from, so any start would be a guess. It is no longer the
  /// path a platform without an obfuscated data plane takes on an obfuscated
  /// region, because such a region advertises `native` and is started on it.
  void _applyRung(DialParams dial) {
    if (_promotionFallbackRung != null &&
        !identical(dial, _promotionFallbackDial)) {
      _promotionFallbackRung = null;
      _promotionFallbackDial = null;
    }
    final next = _rungFor(dial);
    if (next == null) {
      throw UnsupportedError(
        'The server "${dial.serverName}" offers no transport this app build '
        'can use. Choose another server.',
      );
    }
    if (next == _transportRung) return;
    AppLog.info(
      'transport rung set ${_transportRung.name} -> ${next.name} '
      'server=${dial.serverName}',
    );
    _transportRung = next;
  }
}
