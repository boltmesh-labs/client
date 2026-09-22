import '../data/models.dart';

/// Pure dead-server failover policy extracted from [ConnectionController].
///
/// Kept free of Riverpod/timers/storage so it can be unit-tested in
/// isolation. Thresholds live with the controller; only the decision
/// functions live here.

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
  int healThreshold = 2,
  int maxFailovers = 3,
  DateTime? lastStatusAt,
  DateTime? now,
  Duration quietFor = const Duration(seconds: 15),
}) =>
    autoFailoverAttempts < maxFailovers &&
    autoHealAttempts >= healThreshold &&
    (pollFailures >= 1 ||
        _backendQuiet(
          lastStatusAt: lastStatusAt,
          now: now,
          quietFor: quietFor,
        ));

/// Slow-track escalation signal: true when no status poll has proven the
/// backend reachable within [quietFor] — either no poll ever succeeded
/// ([lastStatusAt] null, e.g. the outage started before the first 60s
/// poll) or the last success is older than [quietFor].
///
/// A null [now] (callers without a clock) disables the slow-track so the
/// poll-failure gate stays the only signal. The default [quietFor] mirrors
/// [ConnectionTuning.backendQuietFor] (kept as a literal: domain stays
/// free of the state layer; the controller always passes the tuned value
/// explicitly). It only stops a *recently proven* reachable backend from
/// escalating, it never triggers extra polls.
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
  int pollThreshold = 1,
  DateTime? lastStatusAt,
  DateTime? now,
  Duration quietFor = const Duration(seconds: 15),
}) =>
    pollFailures >= pollThreshold ||
    _backendQuiet(lastStatusAt: lastStatusAt, now: now, quietFor: quietFor);

/// Picks the replacement target for an automatic failover.
///
/// Same-region-first, then global lowest-load: servers in [currentRegionId]
/// (excluding [currentServerId]) win by lowest `activePeers`; when the
/// region has no other capacity, the lowest-load server anywhere wins —
/// unless [stayInRegion] is set (explicit user region/server pin), in which
/// case cross-region moves are forbidden and null is returned instead.
/// A null [currentRegionId] (unpinned quick-connect) picks globally.
/// Always server-targeted (never region-targeted): a region move could
/// reassign the same dead server, while a server move deterministically
/// excludes it. Null when no other server has capacity.
({String? regionId, String? serverId})? pickFailoverTarget({
  required List<Region> regions,
  required String? currentRegionId,
  required String currentServerId,
  bool stayInRegion = false,
}) {
  DiscoveryServer? bestInRegion;
  DiscoveryServer? bestGlobal;
  for (final r in regions) {
    if (!r.hasCapacity) continue;
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
  final best = stayInRegion ? bestInRegion : (bestInRegion ?? bestGlobal);
  if (best == null) return null;
  return (regionId: null, serverId: best.id);
}
