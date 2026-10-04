part of 'connection_controller.dart';

/// The transport rungs, in cost order: the order [_demoteRung] walks.
///
/// Native costs an unobstructed network nothing. AmneziaWG is the middle rung:
/// obfuscated datagrams, no extra moving parts. Stream is the last: the tunnel
/// rides a TLS session to the node, which is what defeats a network that blocks
/// or fingerprints WireGuard's own UDP, and costs the most when it fails.
///
/// The order is the walk order, but where the walk *starts* is the serving
/// server's, not the process's: a stock server's node runs stock WireGuard, so
/// native is its floor, while an obfuscated server's node runs the AmneziaWG
/// device, so a stock datagram is illegible to it — native is not a cheap probe
/// there but a guaranteed-failed attempt that would put a plaintext WireGuard
/// handshake on the wire first. See [_rungFor].
///
/// The rungs are alternatives — one at a time, never stacked — but the *inner*
/// WireGuard format follows the server, not the rung: an obfuscated server's
/// node runs the AmneziaWG device, so the datagrams it receives must carry the
/// obfuscation directives whether they arrive directly (AWG) or inside a stream
/// transport. The stream's TLS session is the outer camouflage; the inner
/// format still has to match the node's device.
enum ObfuscationRung {
  /// The kernel WireGuard data plane, pointed straight at the node.
  native,

  /// The in-process AmneziaWG device.
  awg,

  /// The tunnel's datagrams carried inside a TLS session to the node — the same
  /// WireGuard tunnel, wrapped so a network that blocks or fingerprints
  /// WireGuard's own UDP sees ordinary HTTPS. Not a second VPN: the conf is a
  /// normal one pointed at a loopback bridge the privileged helper runs for the
  /// tunnel's lifetime, so every local health signal reads the same as on the
  /// rungs below it. It is last because it is the most expensive and most
  /// breakable; see the README's *What the stream rung actually is* for the
  /// wire format and what the client has to already have to select it.
  stream,
}

/// The obfuscation ladder. Where it *starts* is the serving server's data plane
/// — a stock server starts on native, an obfuscated one on AmneziaWG, because
/// its node cannot read a stock datagram (see [_rungFor]) — and every rung below
/// that is reached only when the health policy sees a dead tunnel path while
/// the control plane is reachable (see [_demoteRung]).
///
/// The demotion rides the existing heal rung — [_autoHeal] already restarts the
/// cached config offline, which is exactly the moment a fingerprint-blocked path
/// should be retried on a lower rung — but only when the control plane is
/// reachable, so a general blackout does not demote the transport. This adds
/// no recovery budget or polling timer. After a long healthy period, the health
/// tick may probe one cheaper rung; the last known-working rung remains the
/// rollback target until the candidate proves live.
extension ConnectionObfuscation on ConnectionController {
  /// The rung this process is on. Demotions stay sticky across connects to
  /// avoid re-paying for a failed path. The health tick may probe one cheaper
  /// rung after [ConnectionTuning.rungPromotionHealthyFor]; it returns to the
  /// known-working rung if liveness is not confirmed within
  /// [ConnectionTuning.rungPromotionProbeTimeout]. Region changes also move the
  /// rung to the new floor or the highest rung that server can serve.
  ObfuscationRung get obfuscationRung => _obfuscationRung;

  /// The obfuscation parameters to build a conf for [dial] with, or null when
  /// this start's tunnel is stock WireGuard.
  ///
  /// Only the obfuscated rung applies them, because it is the only one pointed at
  /// the node's obfuscated device. The other two are stock: the native rung by
  /// definition, and the stream rung because the node's bridge injects into its
  /// *stock* device no matter what that server's obfuscation settings are — so a
  /// stream session carries stock datagrams inside its TLS session.
  ///
  /// That is the difference from the single-device node this replaced, where an
  /// obfuscated server's only tunnel was the AmneziaWG device and the stream rung
  /// had to carry obfuscated datagrams into it.
  ObfuscationParams? _obfuscationParamsFor(DialParams dial) {
    if (_obfuscationRung != ObfuscationRung.awg) return null;
    final obf = dial.obfuscation;
    return obf != null && obf.isAwg ? obf.params : null;
  }

  /// The node's own UDP port for the rung this start is on.
  ///
  /// `awgPort` on the obfuscated rung, `wgPort` on stock. The two are not
  /// interchangeable in either direction, because the node runs a *separate device*
  /// per transport: a stock device cannot read obfuscation directives, and an
  /// obfuscated device cannot read a stock handshake.
  ///
  /// Falls back to `wgPort` when the descriptor is AWG but no `awg_port` came with
  /// it. That is the shape of a backend predating the field, and dialling the one
  /// port such a backend knows about is the only thing left to try; the rung is
  /// never selected for it anyway, since a server that cannot name the port is not
  /// offering the rung.
  int _tunnelPortFor(DialParams dial) {
    if (_obfuscationRung == ObfuscationRung.awg) {
      final obf = dial.obfuscation;
      if (obf != null && obf.isAwg && dial.awgPort != null) {
        return dial.awgPort!;
      }
    }
    return dial.wgPort;
  }

  /// The overlay address this start must claim.
  ///
  /// The node has one network per device, so the address follows the rung rather
  /// than the server: the obfuscated device routes only the addresses its own
  /// overlay contains, and a stock address sent there handshakes fine and then
  /// blackholes every packet — which reads as a blocked network and demotes the
  /// rung that was working.
  ///
  /// Only the obfuscated rung has a second address. The stream rung is stock
  /// because the node's bridge injects into its *stock* device: a stream session
  /// carries stock WireGuard datagrams whatever the server's obfuscation settings
  /// say, and handing those to the obfuscated device is a handshake into a void.
  String _overlayAddressFor(DialParams dial) {
    if (_obfuscationRung == ObfuscationRung.awg) {
      final awgAddress = dial.awgAssignedIp;
      if (awgAddress != null && awgAddress.isNotEmpty) return awgAddress;
    }
    return dial.assignedIp;
  }

  /// The in-tunnel resolver for this start.
  ///
  /// Same rule as the address: the node runs one systemd-resolved stub per
  /// interface, so the resolver has to be the one on the device this start's
  /// traffic reaches. Pushing the stock stub's address onto the obfuscated rung
  /// would send every DNS query to a device with no route for it.
  String _overlayDnsFor(DialParams dial) {
    if (_obfuscationRung == ObfuscationRung.awg) {
      final awgDns = dial.awgDns;
      if (awgDns != null && awgDns.isNotEmpty) return awgDns;
    }
    return dial.wgDns;
  }

  /// Whether the obfuscated rung has everything it needs to be built.
  ///
  /// The port alone is no longer enough: the rung also needs an address on the
  /// node's obfuscated overlay. A server advertising the descriptor without one is
  /// asking for a conf whose every packet the node cannot route — so the rung is
  /// treated as not offered rather than offered and broken, which is what the
  /// control plane's withholding on its side is for.
  bool _awgRungAvailable(DialParams dial) {
    final obf = dial.obfuscation;
    if (obf == null || !obf.isAwg || !awgDataPlaneSupported()) return false;
    final hasAddress =
        dial.awgAssignedIp != null && dial.awgAssignedIp!.isNotEmpty;
    return hasAddress && dial.awgPort != null;
  }

  /// The stream transport for this start, or null unless this process is on the
  /// stream rung.
  ///
  /// Returns null when the server offers no credential, and throws when the rung
  /// is selected but the platform or daemon cannot run it: those are different
  /// problems, and silently falling back to the native rung would defeat the
  /// heal that put us here by retrying the path just proven dead.
  Future<TunnelTransport?> _streamTransportFor(DialParams dial) async {
    if (_obfuscationRung != ObfuscationRung.stream) return null;
    final credential = dial.stream;
    if (credential == null || !credential.isUsable) {
      throw StateError('Stream rung selected without a usable credential.');
    }
    if (!streamTransportSupported()) {
      throw UnsupportedError(
        'Stream transport is not available on this platform.',
      );
    }
    if (!_daemonCapabilities.contains(capStreamTransport)) {
      throw UnsupportedError(
        'The installed helper cannot run a stream transport.',
      );
    }
    final ports = await allocateLoopbackPorts();
    return TunnelTransport(
      listen: '${TunnelTransport.loopbackHost}:${ports.listen}',
      deliver: '${TunnelTransport.loopbackHost}:${ports.deliver}',
      credential: credential,
    );
  }

  /// Moves the process one rung down when [dial]'s region can serve the next
  /// one. Idempotent: a process already on the last usable rung reports false,
  /// so the heal that demotes is also the only one that can.
  ///
  /// The walk is a single step, not a jump: a heal that moves native directly
  /// to stream would skip the cheaper rung and, if the stream failed, leave no
  /// evidence about whether AWG would have worked.
  ///
  /// [why] is the health reason that triggered the heal, so the log names the
  /// evidence the demotion acted on.
  bool _demoteRung(DialParams dial, String why) {
    final next = _nextRungFor(dial);
    if (next == null) return false;
    AppLog.info(
      'transport demoted ($why) ${_obfuscationRung.name} -> ${next.name}',
    );
    _obfuscationRung = next;
    return true;
  }

  /// The next cheaper rung this server can run, or null at its floor.
  ObfuscationRung? _cheaperRungFor(DialParams dial) {
    final obf = dial.obfuscation;
    final floor = obf != null && obf.isAwg
        ? ObfuscationRung.awg
        : ObfuscationRung.native;
    for (
      var index = _obfuscationRung.index - 1;
      index >= floor.index;
      index--
    ) {
      final candidate = ObfuscationRung.values[index];
      if (candidate == ObfuscationRung.native ||
          (candidate == ObfuscationRung.awg && _awgRungAvailable(dial))) {
        return candidate;
      }
    }
    return null;
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
            maxHealsAfterMoveBudget: ConnectionTuning.maxHealsAfterMoveBudget,
          ) ||
          currentConnectedAt == null ||
          _clock.now().difference(currentConnectedAt) <
              ConnectionTuning.rungPromotionHealthyFor ||
          _cheaperRungFor(dial) != candidate) {
        return;
      }

      final sessionEpoch = _sessionEpoch;
      final previousRung = _obfuscationRung;
      final previousHealAttempts = snap.autoHealAttempts;
      final previousFailoverAttempts = snap.autoFailoverAttempts;
      final previousPollFailures = snap.pollFailures;
      _promotionFallbackRung = previousRung;
      _promotionFallbackDial = dial;
      _obfuscationRung = candidate;
      final recoveryAction = switch (candidate) {
        ObfuscationRung.native => RecoveryAction.tryingNative,
        ObfuscationRung.awg => RecoveryAction.tryingAwg,
        ObfuscationRung.stream => RecoveryAction.tryingStream,
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
        _obfuscationRung = previousRung;
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
      'transport promotion confirmed ${previous.name} -> ${_obfuscationRung.name}',
    );
    _promotionFallbackRung = null;
    _promotionFallbackDial = null;
  }

  /// The rung one step below the current one that [dial] can actually serve,
  /// or null when there is nothing below to walk onto.
  ///
  /// Split out of [_demoteRung] so the health tick can ask whether a heal
  /// would lower the rung *before* spending one, without mutating it: the
  /// ladder is only worth a restart when there is a rung underneath it.
  ObfuscationRung? _nextRungFor(DialParams dial) => switch (_obfuscationRung) {
    ObfuscationRung.native => _firstAvailableRung(dial),
    ObfuscationRung.awg =>
      _streamRungAvailable(dial) ? ObfuscationRung.stream : null,
    // Nothing below stream: a heal here escalates through the existing
    // failover instead of retrying a rung that does not exist.
    ObfuscationRung.stream => null,
  };

  /// Whether a heal against [dial] would leave the rung lower. Pure: it reads
  /// the ladder without moving it, so a caller can gate on it and leave the
  /// ladder alone when the answer is no.
  bool _hasLowerRung(DialParams dial) => _nextRungFor(dial) != null;

  /// The first rung below native that [dial]'s server and this platform can
  /// actually run, preferring AWG because it is the cheaper one.
  ObfuscationRung? _firstAvailableRung(DialParams dial) {
    if (_awgRungAvailable(dial)) return ObfuscationRung.awg;
    if (_streamRungAvailable(dial)) return ObfuscationRung.stream;
    return null;
  }

  /// Whether the stream rung could run here at all: the server must offer a
  /// usable credential, this platform must have a data plane for it, and the
  /// installed daemon must advertise the capability. All three, because
  /// selecting the rung without any of them can only fail.
  ///
  /// A node that also serves the obfuscated rung adds nothing here. The stream's
  /// inner datagrams are stock regardless of that server's settings, because the
  /// node's bridge injects them into its *stock* device — which is exactly why the
  /// stream rung needs no obfuscated data plane on this side, and why a platform
  /// without one can still reach such a server over TLS.
  bool _streamRungAvailable(DialParams dial) {
    final credential = dial.stream;
    if (credential == null ||
        !credential.isUsable ||
        !streamTransportSupported() ||
        !_daemonCapabilities.contains(capStreamTransport)) {
      return false;
    }
    return true;
  }

  /// The rung to start [dial] on, given the process's current one.
  ///
  /// Two rules, both about the serving server rather than the network:
  ///
  ///  * Never start below the server's floor, which is the cheapest rung that
  ///    server can actually serve. A stock server's node runs stock WireGuard, so
  ///    native is that rung. A server serving the obfuscated rung also keeps a
  ///    stock device, on its own port — so a native start there is legitimate and
  ///    does not leak a plaintext handshake at an obfuscated listener. A server
  ///    advertising that rung *incompletely* (no port, or no address on the
  ///    obfuscated overlay) has no such device, so its floor is native too; see
  ///    [_awgRungAvailable].
  ///  * Never keep a rung the server cannot serve. A server move can land on a
  ///    server with no stream credential, where a sticky stream rung could only
  ///    throw (see [_streamTransportFor]).
  ///
  /// The health policy's demotion survives both: this only raises to the floor
  /// and lowers to the ceiling, so a walk down the ladder is never undone.
  ///
  /// A server whose format this build cannot produce a datagram for — an
  /// obfuscated server off Linux (see `platform_info.dart`) — has no rung at
  /// all, and null says so. Selection keeps such a server out of Auto and out of
  /// the failover candidates ([regionServable]), so this is reached only by a
  /// target the user pinned or the control plane handed back; [_applyRung]
  /// refuses rather than sending a native start the node cannot read.
  ObfuscationRung? _rungFor(DialParams dial) {
    final obf = dial.obfuscation;
    if (!formatServable(obf)) return null;
    // Floored at AWG only while this build can actually run the obfuscated data
    // plane *and* the server has it properly configured. Where either is missing
    // the native floor is not a cheap probe but the only rung a conf can be built
    // for — and a conf pointed at the obfuscated port with a stock body, or with
    // an address the obfuscated overlay does not contain, would fail in a way the
    // health ladder reads as a blocked network.
    final floor = _awgRungAvailable(dial)
        ? ObfuscationRung.awg
        : ObfuscationRung.native;
    final ceiling = _streamRungAvailable(dial) ? ObfuscationRung.stream : floor;
    if (_obfuscationRung.index < floor.index) return floor;
    if (_obfuscationRung.index > ceiling.index) return ceiling;
    return _obfuscationRung;
  }

  /// Applies [_rungFor] before a start, logging the move, and refuses a server
  /// whose format this build cannot run.
  ///
  /// Called at the top of every [_startWith] — the one point a connect, a
  /// switch, a heal and a cold restore all pass through — so a move onto a
  /// server with a different format can never start on the previous server's
  /// rung, and an obfuscated server can never start native.
  ///
  /// Refusing is the point: the node would reject every datagram this side could
  /// send, so a native start there cannot connect and leaks the plaintext
  /// handshake doing it. Selection keeps these servers out of the automatic
  /// paths, so reaching this names a target the user chose or the control plane
  /// returned.
  void _applyRung(DialParams dial) {
    if (_promotionFallbackRung != null &&
        !identical(dial, _promotionFallbackDial)) {
      _promotionFallbackRung = null;
      _promotionFallbackDial = null;
    }
    final next = _rungFor(dial);
    if (next == null) {
      throw UnsupportedError(
        'The server "${dial.serverName}" runs obfuscated WireGuard, '
        'which this build cannot run. Choose a server with a stock data plane.',
      );
    }
    if (next == _obfuscationRung) return;
    AppLog.info(
      'transport rung set ${_obfuscationRung.name} -> ${next.name} '
      'server=${dial.serverName}',
    );
    _obfuscationRung = next;
  }
}
