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

  /// Gateway dead (or the handshake is hard-stale) but the control plane
  /// answers: the current node path is dead — skip the offline restart and
  /// fast-track to refresh/failover.
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
/// - [apiReachable] is the out-of-band control-plane probe (Layer 3);
///   null means errored — treated as unknown, which falls back to
///   [ConnectionFailureCause.totalBlackout] so a broken probe can never
///   trigger a server move on its own.
/// - [hardStalled] is the handshake hard-stale verdict (see
///   [ConnectionTuning.hardHandshakeStaleAfter]): a supported reader's
///   handshake that stayed dead past the hard ceiling. It substitutes for a
///   *performed* dead echo when the echo is unprobeable, so a reachable
///   control plane can still fast-track; without it a null echo falls
///   through to the cheap local ladder.
ConnectionFailureCause classifyFailure({
  required bool hasNetwork,
  required bool? gatewayAlive,
  required bool? apiReachable,
  bool hardStalled = false,
}) {
  if (!hasNetwork) return ConnectionFailureCause.noLocalNetwork;
  if (gatewayAlive == true) return ConnectionFailureCause.transientFlap;
  // The fast-track (skip the offline restart, go straight to
  // refresh/failover) requires positive path-dead evidence: a *performed*
  // dead echo, or a handshake that stayed dead past the hard ceiling (the
  // echo may be unprobeable). A skipped/errored echo with a fresh handshake
  // still falls through to the cheap local ladder even when the control
  // plane answers.
  if ((gatewayAlive == false || hardStalled) && apiReachable == true) {
    return ConnectionFailureCause.tunnelPathDead;
  }
  return ConnectionFailureCause.totalBlackout;
}
