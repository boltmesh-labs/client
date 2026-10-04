import '../data/models.dart';

/// Pure dead-server failover policy extracted from [ConnectionController].
///
/// Kept free of Riverpod/timers/storage so it can be unit-tested in
/// isolation. Thresholds live with the controller; only the decision
/// functions live here.
///
/// The policy parameters ([healThreshold], [maxFailovers],
/// [pollThreshold], [quietFor], [controlPlaneReachable]) are required rather
/// than defaulted: a silent default would be a second copy of the tuned value
/// in `ConnectionTuning`, and the two drifting apart is exactly how a retune
/// stops taking effect. Callers pass the constant; tests pass an explicit
/// value.

/// True when a corroborated stall should escalate from a same-server
/// offline restart to switching to a different server.
///
/// The caller must already have detected a stall (frozen RX corroborated by
/// poll failures or a degraded stage). On top of that:
/// - at least [healThreshold] same-server heals must have failed to fix it
///   (cheap restarts cover transient stalls first);
/// - fewer than [maxFailovers] automatic moves may have run this session
///   (bounds ping-ponging between dead servers; the health-tick cadence is
///   the backoff);
/// - the control plane must be positively reachable ([controlPlaneReachable]
///   is the caller's fresh `ControlPlaneProbe` result, not an inference from
///   the poll counters). A failed or unknown probe cannot support a move:
///   discovery and the switch POST would only fail, and the attempt would
///   stop a tunnel and spend the move budget for nothing;
/// - the backend must look unreachable: either at least one status-poll
///   transport failure was observed ([pollFailures] >= 1), or no status poll
///   has succeeded within [quietFor] (slow-track for outages that start
///   between the 60s polls — without this a dead server heals the same
///   config for minutes before the first failed poll lands). A tx-stall
///   with a recently-proven-reachable backend stays on same-server
///   restarts: the server is alive enough to answer the control plane.
bool shouldEscalateToFailover({
  required int autoHealAttempts,
  required int autoFailoverAttempts,
  required int pollFailures,
  required bool controlPlaneReachable,
  required int healThreshold,
  required int maxFailovers,
  required Duration quietFor,
  DateTime? lastStatusAt,
  DateTime? now,
}) =>
    controlPlaneReachable &&
    autoFailoverAttempts < maxFailovers &&
    autoHealAttempts >= healThreshold &&
    (pollFailures >= 1 ||
        _backendQuiet(
          lastStatusAt: lastStatusAt,
          now: now,
          quietFor: quietFor,
        ));

/// Whether a local cached-tunnel restart is still allowed for this failure
/// incident.
///
/// Before the move budget is spent the cap is [maxHealsPerIncident], which is
/// what lets the transport ladder walk more than one rung on a node that serves
/// more than one below its floor — a restart can recover a wedged native tunnel
/// without changing the server-side peer, and each of them is also one rung step
/// down the ladder (see `ladder_policy.dart`). Once the move budget is spent
/// there is nowhere to move, so the trailing [maxHealsAfterMoveBudget] applies
/// instead: further restarts are not useful evidence of recovery, so the
/// controller waits for the control plane rather than flapping the same tunnel.
bool canAttemptAutoHeal({
  required int autoHealAttempts,
  required int autoFailoverAttempts,
  required int maxFailovers,
  required int maxHealsPerIncident,
  required int maxHealsAfterMoveBudget,
}) {
  // Both limits are read from `ConnectionTuning` at the call site, so a retune
  // there is a retune here.
  final limit = autoFailoverAttempts >= maxFailovers
      ? maxHealsAfterMoveBudget
      : maxHealsPerIncident;
  return autoHealAttempts < limit;
}

/// Slow-track escalation signal: true when no status poll has proven the
/// backend reachable within [quietFor] — either no poll ever succeeded
/// ([lastStatusAt] null, e.g. the outage started before the first 60s
/// poll) or the last success is older than [quietFor].
///
/// A null [now] (callers without a clock) disables the slow-track so the
/// poll-failure gate stays the only signal. It only stops a *recently proven*
/// reachable backend from escalating, it never triggers extra polls.
bool _backendQuiet({
  required DateTime? lastStatusAt,
  required DateTime? now,
  required Duration quietFor,
}) {
  if (now == null) return false;
  final at = lastStatusAt;
  if (at == null) return true;
  return now.difference(at) >= quietFor;
}

/// True when local stall evidence may act: the backend looks unreachable,
/// either via an observed status-poll transport failure ([pollFailures] >=
/// [pollThreshold]) or via the slow-track (no poll success within
/// [quietFor], including never-polled).
///
/// Gates *detection*, not just escalation: an upload-only tunnel shows the
/// same TX-growing/RX-frozen signature as a data-plane deadlock (and
/// Android's truncated-KB counters turn boundary crossings into apparent
/// 1KB jumps), so a recently-proven-reachable backend must suppress the
/// heal entirely instead of merely staying on same-server restarts.
bool isBackendCorroborated({
  required int pollFailures,
  required int pollThreshold,
  required Duration quietFor,
  DateTime? lastStatusAt,
  DateTime? now,
}) =>
    pollFailures >= pollThreshold ||
    _backendQuiet(lastStatusAt: lastStatusAt, now: now, quietFor: quietFor);

/// Picks the replacement server for an automatic failover.
///
/// Same-region-first, then global lowest-load: servers in [currentRegionId]
/// (excluding [currentServerId]) win by lowest `activePeers`; when the
/// region has no other capacity, the lowest-load server anywhere wins.
/// A null [currentRegionId] (unpinned quick-connect) picks globally.
///
/// [currentRegionId] is a preference, not a boundary: a pinned server whose
/// region is full or gone still roams, and the caller drops the pin to Auto
/// when the pick leaves the region (see `_recordAutoFailoverSuccess`).
/// The picked server deterministically excludes the dead one. Null when no
/// other server has capacity anywhere.
String? pickFailoverTarget({
  required List<Region> regions,
  required String? currentRegionId,
  required String currentServerId,
}) {
  DiscoveryServer? bestInRegion;
  DiscoveryServer? bestGlobal;
  for (final r in regions) {
    if (!r.hasCapacity) continue;
    // No per-region format filter: every server advertises `native`, so every
    // region with capacity is a legal place to move to. Whether a specific rung
    // is buildable is decided at the new server's start, where the rung list is
    // known.
    for (final s in r.servers) {
      if (s.id == currentServerId) continue;
      if (bestGlobal == null || s.activePeers < bestGlobal.activePeers) {
        bestGlobal = s;
      }
      if (currentRegionId != null &&
          r.id == currentRegionId &&
          (bestInRegion == null || s.activePeers < bestInRegion.activePeers)) {
        bestInRegion = s;
      }
    }
  }
  return (bestInRegion ?? bestGlobal)?.id;
}
