/// Pure transport-ladder policy: which recovery step one health tick takes.
///
/// Kept free of Riverpod/timers/storage (like `failover_policy.dart`) so the
/// ordering can be unit-tested in isolation. Thresholds live in
/// `ConnectionTuning`; the caller reads them and passes them in, so a retune
/// there is a retune here.
///
/// [RecoveryDecision] is deliberately named apart from the UI's `RecoveryAction`
/// (see `connection_state.dart`): this is the pure policy output, that is the
/// user-visible step the tick then publishes.
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
///    [RecoveryDecision.demoteTransport]).
///  * A stall that survives a heal escalates to a server move, and a stall with
///    no budget left waits or surfaces instead of flapping the tunnel.
///
/// The decision is split in two because Layer 3 is real I/O: the caller must
/// not probe the control plane on a tick that a local signal already decided.
/// [decideLocalRecovery] answers from Layers 2 and 1 alone and returns
/// [RecoveryDecision.probeControlPlane] when only Layer 3 can decide; the caller
/// probes once and asks [decideRecoveryStep].
enum RecoveryDecision {
  /// Layer 2: the OS reports no usable link. Wait for it to come back.
  pauseNoNetwork,

  /// Layer 1: the in-tunnel echo answered, so the data path is alive. Do not
  /// touch a working tunnel (a backend-attributed dead node excepted — see
  /// [_pathConfirmedDead]).
  suppressHealthy,

  /// Local evidence confirms the current path is dead and no rung step is
  /// available, so the same-server heal would only rebuild the config this
  /// client already knows is dead. Move servers without spending a heal.
  moveServer,

  /// Only the control-plane probe can decide this tick.
  probeControlPlane,

  /// Restart the tunnel one rung cheaper. The only step that demotes a
  /// transport. Licensed by positive *local* evidence that this path is dead
  /// (a performed-dead echo run, the hard handshake ceiling, or a handshake
  /// that never completed past its grace) when a rung below is affordable; it
  /// does not wait for the control plane, which is routed through the very rung
  /// under test and so cannot corroborate a blocked transport.
  demoteTransport,

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

/// Whether this tick's evidence positively identifies a dead tunnel path.
///
/// This is the bit the ladder consumes from the 4-layer diagnostic pipeline.
/// It used to live in `diagnosis_policy.dart` as a four-variant
/// `ConnectionFailureCause`, but the ladder only ever tested the one value
/// "path confirmed dead": the other three were either short-circuited by the
/// callers (`noLocalNetwork` on the link read, `transientFlap` on a live echo)
/// or collapsed into the not-dead answer (`totalBlackout`). The enum and the
/// second representation of the same evidence it kept are therefore folded back
/// into the one question asked here.
///
/// The ordering is the whole content:
///
///  * [serverConfirmedDown] is the backend's own verdict on the serving node —
///    the only *attributed* signal here. It outranks a live echo: the echo is a
///    symptom read (the node answered one datagram, plausibly an overlapping
///    heartbeat while it restarts) where the verdict is the cause, and honoring
///    the echo would park the session on a node the backend has given up on.
///  * A live echo ([gatewayAlive] true) means the data path is healthy, so
///    nothing else may call it dead.
///  * [hardStalled] (an observed handshake past the hard ceiling) and
///    [confirmedLocalPathDeath] (a performed-dead echo run) are positive local
///    evidence and need no corroboration.
///  * A single performed-dead echo ([gatewayAlive] false) fast-tracks only once
///    the control plane has answered ([apiReachable] true): one dropped
///    datagram is not path death, and the probe may itself travel the path
///    under test.
///  * [neverHandshookPastGrace] is real local evidence too, but only while the
///    control plane answers — the same cost-of-action rule: it licenses the
///    cheap same-server rung step, while the uncorroborated move waits for the
///    later hard ceiling instead.
///
/// A null [gatewayAlive] or [apiReachable] is unknown, never death.
bool _pathConfirmedDead({
  required bool? gatewayAlive,
  required bool? apiReachable,
  required bool serverConfirmedDown,
  required bool hardStalled,
  required bool neverHandshookPastGrace,
  required bool confirmedLocalPathDeath,
}) {
  if (serverConfirmedDown) return true;
  if (gatewayAlive == true) return false;
  if (hardStalled || confirmedLocalPathDeath) return true;
  if (gatewayAlive == false && apiReachable == true) return true;
  if (neverHandshookPastGrace && apiReachable == true) return true;
  return false;
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
///
/// Deliberately a pure predicate over one tick, with no step counter of its own:
/// the step is *one* rung and is idempotent — the caller reads the ladder off
/// the dial, so a rung with nothing below it offers no step however healthy the
/// budget is, and a rung with one below it offers exactly one. How many steps an
/// incident may take is therefore the heal budget's alone
/// (`ConnectionTuning.maxHealsPerIncident`, via `canAttemptAutoHeal`), which is
/// what keeps the walk's length and the ladder's length from disagreeing.
bool rungStepAvailable({
  required bool serverConfirmedDown,
  required bool lowerRungAvailable,
  required bool canHeal,
}) => !serverConfirmedDown && lowerRungAvailable && canHeal;

/// The decision available from the OS link and the in-tunnel echo, before any
/// control-plane probe.
///
/// Returns [RecoveryDecision.probeControlPlane] for every cell that only Layer 3
/// can settle — including the ones that will later heal or demote, because a
/// restart or a rung step is decided after the probe so a live control plane
/// can still suppress it.
///
/// [lowerRungAvailable] is the pure capability question ("would a heal lower
/// the rung?"), not the budget-aware one; see [rungStepAvailable].
RecoveryDecision decideLocalRecovery({
  required bool hasNetwork,
  required bool? gatewayAlive,
  required bool serverConfirmedDown,
  required bool confirmedLocalPathDeath,
  required bool hardStalled,
  required bool lowerRungAvailable,
  required bool canHeal,
  required bool moveBudgetLeft,
}) {
  if (!hasNetwork) return RecoveryDecision.pauseNoNetwork;
  if (gatewayAlive == true && !serverConfirmedDown) {
    return RecoveryDecision.suppressHealthy;
  }
  // Local evidence alone, with the control plane deliberately null: a probe
  // made while this tunnel still routes traffic can fail *because* the path is
  // broken, so a fast-track must not depend on it. The never-handshook verdict
  // is not consulted here at all: it is honored only when the probe answered,
  // and this call says it did not.
  final pathDead = _pathConfirmedDead(
    gatewayAlive: gatewayAlive,
    apiReachable: null,
    hardStalled: hardStalled,
    neverHandshookPastGrace: false,
    serverConfirmedDown: serverConfirmedDown,
    confirmedLocalPathDeath: confirmedLocalPathDeath,
  );
  if (pathDead &&
      moveBudgetLeft &&
      !rungStepAvailable(
        serverConfirmedDown: serverConfirmedDown,
        lowerRungAvailable: lowerRungAvailable,
        canHeal: canHeal,
      )) {
    return RecoveryDecision.moveServer;
  }
  return RecoveryDecision.probeControlPlane;
}

/// The decision once the Layer 3 probe has been read.
///
/// The caller must already have a usable link — [decideLocalRecovery] pauses
/// otherwise, and nothing here may act on a down link. A null [apiReachable]
/// is a probe that errored: unknown, which can never license a move (the cheap
/// rung step is licensed by local path-death evidence instead).
///
/// [escalateToMove] is `shouldEscalateToFailover`'s verdict for this tick (the
/// heal threshold, the move budget and the backend-quiet gate). It is a separate
/// step from [RecoveryDecision.moveServer] rather than the same one because the two
/// carry different evidence into the move: a fast-track is a confirmed dead
/// path, while an escalation is a stall that outlived a heal.
RecoveryDecision decideRecoveryStep({
  required bool? gatewayAlive,
  required bool? apiReachable,
  required bool serverConfirmedDown,
  required bool confirmedLocalPathDeath,
  required bool hardStalled,
  required bool neverHandshookPastGrace,
  required bool lowerRungAvailable,
  required bool canHeal,
  required bool moveBudgetLeft,
  required bool escalateToMove,
}) {
  // Defensive: the caller suppresses on a live echo before probing, but a
  // function that could heal or move a tunnel whose own path just answered
  // would be a trap for the next caller.
  if (gatewayAlive == true && !serverConfirmedDown) {
    return RecoveryDecision.suppressHealthy;
  }
  final pathDead = _pathConfirmedDead(
    gatewayAlive: gatewayAlive,
    apiReachable: apiReachable,
    hardStalled: hardStalled,
    neverHandshookPastGrace: neverHandshookPastGrace,
    serverConfirmedDown: serverConfirmedDown,
    confirmedLocalPathDeath: confirmedLocalPathDeath,
  );
  final canStepRung = rungStepAvailable(
    serverConfirmedDown: serverConfirmedDown,
    lowerRungAvailable: lowerRungAvailable,
    canHeal: canHeal,
  );
  // A single performed-dead echo only reaches here as a confirmed dead path
  // when the control plane answered; a confirmed echo run, a hard-stale
  // handshake or the backend's node verdict carry it without the probe.
  if (pathDead && moveBudgetLeft && !canStepRung) {
    return RecoveryDecision.moveServer;
  }
  if (!canHeal && apiReachable != true) {
    // A move still requires a positive control-plane result: without one,
    // discovery and the switch POST would only fail, so a failed or unknown
    // probe is not a reason to stop a tunnel or spend a move budget.
    return RecoveryDecision.waitForControlPlane;
  }
  if (!canHeal && !moveBudgetLeft) {
    // Nothing left to try, and worth surfacing only because the control plane
    // answered: a terminal decision needs one.
    return RecoveryDecision.surfaceExhausted;
  }
  // Checked before the trailing wait: a stall that outlived its heal is exactly
  // what the escalation gate exists for, and it stays reachable with no heal
  // budget left — there is a move to make, only no restart left to try.
  if (escalateToMove) return RecoveryDecision.escalateToServer;
  if (!canHeal) {
    // Heal budget spent, move budget intact, escalation gate not met: keep the
    // tunnel and wait for fresh positive evidence rather than spending a move
    // on a stall that may not be a dead server.
    return RecoveryDecision.verifyTunnel;
  }
  // The cheap rung step is licensed by *local* path-death evidence alone: a
  // performed-dead echo run, the hard handshake ceiling, or a handshake that
  // never completed past its grace. The control plane is deliberately not
  // required here. It is routed through the very rung under test — in a full
  // tunnel a blocked transport kills the probe too — so requiring it made the
  // step unreachable exactly when it is needed, while the uncorroborated
  // [RecoveryDecision.moveServer] above already acts on the same evidence. Only the
  // cheap action is widened: the move keeps its confirmed-dead-path
  // criterion, so a bare single dead echo still only restarts.
  final locallyDead = pathDead || neverHandshookPastGrace;
  return canStepRung && locallyDead
      ? RecoveryDecision.demoteTransport
      : RecoveryDecision.restartTunnel;
}
