/// Pure failure-cause classification for the 4-layer diagnostic pipeline.
///
/// Kept free of Riverpod/timers/storage (like `failover_policy.dart`) so it
/// can be unit-tested in isolation. Thresholds live in
/// [ConnectionTuning]; only the decision function lives here.
enum ConnectionFailureCause {
  /// OS physical link down: freeze all heal escalation, wait for restore.
  noLocalNetwork,

  /// In-tunnel gateway echo alive: the data path is healthy (likely an
  /// idle user or a transient flap), suppress any recovery.
  transientFlap,

  /// Local evidence identifies a dead current-node path: a confirmed dead
  /// echo run, hard-stale handshake, or backend-down verdict. These signals
  /// can fast-track before the API probe because that probe may use the dead
  /// tunnel. A single dead echo fast-tracks only when the API probe answers.
  tunnelPathDead,

  /// Gateway and control plane both dead (or the control probe was
  /// skipped/unknown): local outage or full block — stay on the cheap
  /// offline restart without burning server-move budgets.
  totalBlackout,
}

/// Maps probe outcomes to a [ConnectionFailureCause].
///
/// - [hasNetwork] comes from the OS link listener (Layer 2).
/// - [gatewayAlive] is the in-tunnel gateway echo result (Layer 1); null
///   means the probe was skipped or errored — unknown, which alone can
///   never fast-track: a skipped probe is absence of evidence, not death.
/// - [apiReachable] is the control-plane probe result (Layer 3). It uses a
///   separate Dio client but follows normal OS routing, so it may itself be
///   routed through WireGuard. Null means errored — treated as unknown.
/// - [confirmedLocalPathDeath] is a multi-tick dead-echo verdict (as opposed
///   to one potentially dropped echo packet).
/// - [hardStalled] is the handshake hard-stale verdict (see
///   [ConnectionTuning.hardHandshakeStaleAfter]): a supported reader's
///   handshake that stayed dead past the hard ceiling. It substitutes for a
///   *performed* dead echo when the echo is unprobeable, and is sufficient to
///   fast-track without a successful control-plane probe.
/// - [serverConfirmedDown] is the backend's own verdict on the serving node
///   (`GET …/server-status`). The only *attributed* death signal here — every
///   other input describes what this client observes, which a local path fault
///   can mimic. It counts as positive path-dead evidence, so a node the
///   backend has given up on skips the same-server heal and starts failover;
///   discovery still has to succeed after the tunnel is stopped.
///   It also outranks [gatewayAlive] being true: the echo is a symptom read
///   (the node answered one datagram, plausibly an overlapping heartbeat
///   while it restarts) where this is the cause, and honoring the echo would
///   park the session on a dead node until the next status poll.
ConnectionFailureCause classifyFailure({
  required bool hasNetwork,
  required bool? gatewayAlive,
  required bool? apiReachable,
  bool hardStalled = false,
  bool serverConfirmedDown = false,
  bool confirmedLocalPathDeath = false,
}) {
  if (!hasNetwork) return ConnectionFailureCause.noLocalNetwork;
  // A backend-confirmed-dead node outranks a live echo. The echo is a
  // symptom read (the node answered one datagram — plausibly an overlapping
  // heartbeat while it restarts); the node verdict is the cause. Letting the
  // echo win here would park the session on a node the backend has already
  // given up on until the next status poll, which is the delay this signal
  // exists to remove.
  if (serverConfirmedDown) {
    return ConnectionFailureCause.tunnelPathDead;
  }
  if (gatewayAlive == true) return ConnectionFailureCause.transientFlap;
  if (hardStalled || confirmedLocalPathDeath) {
    return ConnectionFailureCause.tunnelPathDead;
  }
  // A single performed-dead echo is not enough to fast-track without
  // corroboration: require the control plane to answer. A confirmed echo run,
  // hard-stale handshake, or backend node verdict was handled above and may
  // fast-track before probing the control plane.
  if (gatewayAlive == false && apiReachable == true) {
    return ConnectionFailureCause.tunnelPathDead;
  }
  return ConnectionFailureCause.totalBlackout;
}
