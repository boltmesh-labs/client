import 'diagnosis_policy.dart';

/// Pure transport-ladder policy: which recovery step one health tick takes.
///
/// Kept free of Riverpod/timers/storage (like `failover_policy.dart`) so the
/// ordering can be unit-tested in isolation. Thresholds live in
/// `ConnectionTuning`; the caller reads them and passes them in, so a retune
/// there is a retune here.
///
/// The ordering this encodes is the one a rung change depends on:
///
///  * Layer 2 (OS link) freezes everything.
///  * Layer 1 (in-tunnel echo) alive suppresses recovery — unless the backend
///    already attributed the failure to the node, which is the cause where the
///    echo is only a symptom.
///  * A *confirmed* dead path moves servers when there is nothing cheaper to
///    try. "Cheaper" is one rung step down, so a region that serves a lower
///    rung always gets the heal first: Layer 1 cannot tell a blocked transport
///    from a powered-off node, and a restart costs no move budget.
///  * Only then does the bounded same-server heal run, and it demotes the
///    transport only on positive evidence that this transport is blocked (see
///    [RecoveryStep.stepTransportRung]).
///  * A stall that survives a heal escalates to a server move, and a stall with
///    no budget left waits or surfaces instead of flapping the tunnel.
///
/// The decision is split in two because Layer 3 is real I/O: the caller must
/// not probe the control plane on a tick that a local signal already decided.
/// [decideLocalRecovery] answers from Layers 2 and 1 alone and returns
/// [RecoveryStep.probeControlPlane] when only Layer 3 can decide; the caller
/// probes once and asks [decideRecoveryStep].
enum RecoveryStep {
  /// Layer 2: the OS reports no usable link. Wait for it to come back.
  pauseNoNetwork,

  /// Layer 1: the in-tunnel echo answered, so the data path is alive. Do not
  /// touch a working tunnel (a backend-attributed dead node excepted — see
  /// [classifyFailure]).
  suppressLiveEcho,

  /// Local evidence confirms the current path is dead and no rung step is
  /// available, so the same-server heal would only rebuild the config this
  /// client already knows is dead. Move servers without spending a heal.
  moveServer,

  /// Only the control-plane probe can decide this tick.
  probeControlPlane,

  /// Restart the tunnel one rung cheaper. The only step that demotes a
  /// transport, and only reachable on positive evidence that *this* transport
  /// is blocked: the path looks dead while the control plane answers.
  stepTransportRung,

  /// Restart the tunnel on its current rung. A blackout or an unattributed
  /// stall justifies the restart, but not a transport change.
  restartTunnel,

  /// The heal budget is spent and the control plane is not proven reachable, so
  /// a move could only fail. Wait for it.
  waitForControlPlane,

  /// The move budget and the trailing heal budget are both spent while the
  /// control plane is reachable: there is nothing left to try, so surface an
  /// actionable error instead of healing the same config forever.
  surfaceExhausted,

  /// The heal budget is spent, the move budget is not, and the escalation gate
  /// is not met. Keep the tunnel and wait for fresh positive evidence rather
  /// than spending a move on a stall that may not be a dead server.
  verifyTunnel,

  /// Escalate to a server move: a same-server heal already ran for this
  /// incident and the backend still looks unreachable.
  escalateToServer,
}

/// Whether a heal would demote the transport instead of rebuilding it in place.
///
/// The rung step is only worth a restart when there is a rung underneath, it is
/// only affordable while a heal is affordable, and the backend's node verdict
/// skips it entirely — a server the backend has given up on is not a transport
/// problem, so that case moves servers instead. Keeping all three here (rather
/// than at the call site, where one of them used to sit) is what makes the
/// "the backend verdict skips the ladder" rule a tested row rather than an
/// expression that has to be re-read to be trusted.
bool rungStepAvailable({
  required bool serverConfirmedDown,
  required bool lowerRungAvailable,
  required bool canHeal,
}) => !serverConfirmedDown && lowerRungAvailable && canHeal;

/// The decision available from the OS link and the in-tunnel echo, before any
/// control-plane probe.
///
/// Returns [RecoveryStep.probeControlPlane] for every cell that only Layer 3
/// can settle — including the ones that will later heal or demote, because a
/// transport step is defined by the control plane answering ([RecoveryStep.
/// stepTransportRung]) and cannot be decided without it.
///
/// [lowerRungAvailable] is the pure capability question ("would a heal lower
/// the rung?"), not the budget-aware one; see [rungStepAvailable].
RecoveryStep decideLocalRecovery({
  required bool hasNetwork,
  required bool? gatewayAlive,
  required bool serverConfirmedDown,
  required bool confirmedLocalPathDeath,
  required bool hardStalled,
  required bool lowerRungAvailable,
  required bool canHeal,
  required bool moveBudgetLeft,
}) {
  if (!hasNetwork) return RecoveryStep.pauseNoNetwork;
  if (gatewayAlive == true && !serverConfirmedDown) {
    return RecoveryStep.suppressLiveEcho;
  }
  // Local evidence alone, with the control plane deliberately null: a probe
  // made while this tunnel still routes traffic can fail *because* the path is
  // broken, so a fast-track must not depend on it.
  final cause = classifyFailure(
    hasNetwork: true,
    gatewayAlive: gatewayAlive,
    apiReachable: null,
    hardStalled: hardStalled,
    serverConfirmedDown: serverConfirmedDown,
    confirmedLocalPathDeath: confirmedLocalPathDeath,
  );
  if (cause == ConnectionFailureCause.tunnelPathDead &&
      moveBudgetLeft &&
      !rungStepAvailable(
        serverConfirmedDown: serverConfirmedDown,
        lowerRungAvailable: lowerRungAvailable,
        canHeal: canHeal,
      )) {
    return RecoveryStep.moveServer;
  }
  return RecoveryStep.probeControlPlane;
}

/// The decision once the control plane has answered.
///
/// The caller must already have a usable link — [decideLocalRecovery] pauses
/// otherwise, and nothing here may act on a down link. A null [apiReachable]
/// is a probe that errored: unknown, which can never license a move.
///
/// [escalateToMove] is `shouldEscalateToFailover`'s verdict for this tick (the
/// heal threshold, the move budget and the backend-quiet gate). It is a separate
/// step from [RecoveryStep.moveServer] rather than the same one because the two
/// carry different evidence into the move: a fast-track is a confirmed dead
/// path, while an escalation is a stall that outlived a heal.
RecoveryStep decideRecoveryStep({
  required bool? gatewayAlive,
  required bool? apiReachable,
  required bool serverConfirmedDown,
  required bool confirmedLocalPathDeath,
  required bool hardStalled,
  required bool lowerRungAvailable,
  required bool canHeal,
  required bool moveBudgetLeft,
  required bool escalateToMove,
}) {
  // Defensive: the caller suppresses on a live echo before probing, but a
  // function that could heal or move a tunnel whose own path just answered
  // would be a trap for the next caller.
  if (gatewayAlive == true && !serverConfirmedDown) {
    return RecoveryStep.suppressLiveEcho;
  }
  final cause = classifyFailure(
    hasNetwork: true,
    gatewayAlive: gatewayAlive,
    apiReachable: apiReachable,
    hardStalled: hardStalled,
    serverConfirmedDown: serverConfirmedDown,
    confirmedLocalPathDeath: confirmedLocalPathDeath,
  );
  final canStepRung = rungStepAvailable(
    serverConfirmedDown: serverConfirmedDown,
    lowerRungAvailable: lowerRungAvailable,
    canHeal: canHeal,
  );
  // A single performed-dead echo only reaches here as `tunnelPathDead` when the
  // control plane answered; a confirmed echo run, a hard-stale handshake or the
  // backend's node verdict carry it without the probe.
  if (cause == ConnectionFailureCause.tunnelPathDead &&
      moveBudgetLeft &&
      !canStepRung) {
    return RecoveryStep.moveServer;
  }
  if (!canHeal && apiReachable != true) {
    // A move still requires a positive control-plane result: without one,
    // discovery and the switch POST would only fail, so a failed or unknown
    // probe is not a reason to stop a tunnel or spend a move budget.
    return RecoveryStep.waitForControlPlane;
  }
  if (!canHeal && !moveBudgetLeft) {
    // Nothing left to try, and worth surfacing only because the control plane
    // answered: a terminal decision needs one.
    return RecoveryStep.surfaceExhausted;
  }
  // Checked before the trailing wait: a stall that outlived its heal is exactly
  // what the escalation gate exists for, and it stays reachable with no heal
  // budget left — there is a move to make, only no restart left to try.
  if (escalateToMove) return RecoveryStep.escalateToServer;
  if (!canHeal) {
    // Heal budget spent, move budget intact, escalation gate not met: keep the
    // tunnel and wait for fresh positive evidence rather than spending a move
    // on a stall that may not be a dead server.
    return RecoveryStep.verifyTunnel;
  }
  // The demotion gate: this transport is suspected only when its path looks
  // dead *while the control plane answers*. A blackout can still justify the
  // restart above, but a node answering the API while its tunnel path is dead
  // is the signature of a blocked transport, and that is the only evidence
  // that distinguishes "this rung is blocked" from "the network is gone".
  return canStepRung &&
          apiReachable == true &&
          cause == ConnectionFailureCause.tunnelPathDead
      ? RecoveryStep.stepTransportRung
      : RecoveryStep.restartTunnel;
}
