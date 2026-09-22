/// Tunables for [ConnectionController] health/rotation behavior.
///
/// One home for the numbers previously scattered as `static const`s on the
/// controller, so tests and docs quote a single source. The pure predicates
/// live in `domain/` (failover/tunnel policy); only the values live here.
abstract final class ConnectionTuning {
  /// Status-poll failures before the UI shows a degraded banner.
  static const degradedPollThreshold = 3;

  /// Last-handshake age that marks the peer dead (see [isHandshakeStale]).
  /// WireGuard's 25s persistent keepalive initiates a fresh handshake once
  /// the last one is ~120s old, so 150s still clears a full rekey cycle with
  /// ~30s margin; keepalive traffic only refreshes the session, never the
  /// observed handshake timestamp.
  static const handshakeStaleAfter = Duration(seconds: 150);

  /// How long a *supported* handshake reader may report "no handshake yet"
  /// before the peer counts as dead (see [isHandshakeStale]). The WireGuard
  /// core retries the initial handshake every 5s, so a live peer completes
  /// within seconds; 30s (≈6 retries) still covers slow networks without
  /// anywhere near the full [handshakeStaleAfter] window (which only ages
  /// out an *observed* handshake). Unsupported readers never enter this
  /// branch at all.
  static const firstHandshakeGrace = Duration(seconds: 30);

  /// Observed-handshake age past which a stale handshake acts *without*
  /// backend corroboration. The standard [handshakeStaleAfter] still needs a
  /// poll failure or a quiet backend, which a reachable out-of-band control
  /// plane never provides (WG UDP blocked while the API stays up): polls then
  /// keep resetting the recovery budgets and the ladder can be suppressed
  /// forever. Roughly 1.5 rekey cycles keeps a merely-late rekey from
  /// bypassing corroboration while making recovery deterministic.
  /// The bypass only *enters* the stall; the fast-track rung still requires a
  /// reachable control plane (see [classifyFailure]).
  static const hardHandshakeStaleAfter = Duration(seconds: 180);

  /// Never-handshook ceiling for a *supported* reader once a recovery restart
  /// has happened: the fresh tunnel has no handshake, so the standard
  /// [firstHandshakeGrace] stays corroboration-gated and the ladder could
  /// never progress past the first restart while out-of-band polls succeed.
  /// 60s (2× the grace, ~12 WG retries) is ample even on slow links, and
  /// unsupported readers never enter this branch at all.
  static const hardFirstHandshakeCeiling = Duration(seconds: 60);

  /// Observed-handshake age beyond which a performed-dead in-tunnel gateway
  /// echo shortens the dead-peer window (see [_deadEchoStrikes] and
  /// [isHandshakeStale]). Above the 25s keepalive so a just-handshaked peer
  /// (proven alive) is never overridden by one dead DNS datagram, and far
  /// below [handshakeStaleAfter] so a dead peer is caught shortly after
  /// probing starts (see [echoProbeAfter]) instead of waiting out a full
  /// 120s rekey cycle. A live echo still suppresses, and the shortened
  /// window stays backend-corroborated.
  static const echoStallHandshakeAge = Duration(seconds: 30);

  /// Observed-handshake age at which the in-tunnel echo starts being read
  /// each tick. A fresh handshake already proves the peer alive, and below
  /// [echoStallHandshakeAge] a dead-echo run cannot change the decision
  /// anyway, so probing every tick while the handshake is fresh is pure
  /// steady-state traffic (one UDP datagram per health tick, ~6/min
  /// foreground). Past this age a missing rekey becomes meaningful and the
  /// echo is read to suppress a stale-handshake heal when the data path is
  /// actually alive and to corroborate a dead path. Well inside the ~120s
  /// keepalive rekey, so a data-path death shortly after a handshake is
  /// still caught ~40s after the last handshake (worst case) rather than
  /// the full 150s window; deaths after the gate are unaffected. Degraded
  /// stages and unknown handshakes (never handshook, or no reader) always
  /// probe regardless of age.
  static const echoProbeAfter = Duration(seconds: 30);

  /// Consecutive performed-dead gateway echoes (one per health tick) before
  /// [echoStallHandshakeAge] applies: a single dropped DNS datagram must
  /// never shorten the window. At the 10s tick cadence this confirms the
  /// data-path death in ~40s once probing is active (see [echoProbeAfter]);
  /// the 15s background cadence confirms it in ~45s.
  static const echoStallStrikes = 2;

  /// Status-poll transport failures that corroborate a stale handshake.
  /// Counters are gone from heal decisions, but backend reachability still
  /// gates escalation: a single failure is enough since each already cost a
  /// full 10s connect timeout, and escalation still needs a prior
  /// same-server heal first, so one transient blip can only trigger a cheap
  /// offline restart — never a server move. Combined with poll-failure
  /// preservation across heal restarts, a powered-off server escalates
  /// after one 60s poll instead of two.
  static const handshakeStallPollThreshold = 1;

  /// How long ago a successful status poll still proves the backend
  /// reachable for escalation purposes. Newer than this, a corroborated
  /// stall keeps healing offline (same-server restart) instead of
  /// stopping the tunnel for a failover; older (or never polled),
  /// the stall may escalate on local evidence alone so an outage starting
  /// between the 60s status polls doesn't heal-loop for minutes. Never
  /// triggers extra polls — the 60s status floor is untouched.
  static const backendQuietFor = Duration(seconds: 15);

  /// Same-server heal before a corroborated stall escalates to an
  /// automatic move to a different server.
  static const failoverHealThreshold = 1;

  /// Automatic server moves per connected session. Bounds ping-ponging
  /// while two servers are down; the health-tick cadence is the backoff.
  static const maxAutoFailovers = 3;

  /// Same-server restarts allowed *after* the move budget is spent. Once
  /// there is nowhere left to move, a dead server can only be redialed in
  /// place; a couple of cheap retries cover a transient stall, then the
  /// ladder is surfaced as an actionable error instead of restarting a
  /// proven-dead config on every tick forever (see
  /// [ConnectionRecovery._surfaceRecoveryExhausted]). A successful status
  /// poll or a fresh connect restores the budget.
  static const maxHealsAfterMoveBudget = 2;

  /// Attempt-1 budget for an in-tunnel switch/rotate POST: shorter than
  /// Dio's 15s receive timeout so the direct-network fallback stays snappy.
  static const throughTunnelAttempt = Duration(seconds: 10);

  /// In-tunnel probe budget on the *recovery* paths only (failover discovery
  /// and switch). The path is already suspect when these run — a stall that
  /// survived a same-server restart — so a dead tunnel is abandoned after
  /// [recoveryProbeTimeout] instead of waiting out the full
  /// [throughTunnelAttempt]. Manual switch/rotate keep the longer budget:
  /// the tunnel is healthy there and a slow-but-alive path must not be
  /// flapped.
  static const recoveryProbeTimeout = Duration(seconds: 3);

  /// Budget for the Layer 1 in-tunnel gateway echo (UDP DNS to `wg_dns`).
  /// Well inside the 10s health-tick cadence so a dead gateway never
  /// pushes detection past the next tick.
  static const gatewayProbeTimeout = Duration(seconds: 2);

  /// Budget for the Layer 3 control-plane probe (`GET …/health` on its
  /// own Dio). Shorter than Dio's 15s receive timeout; the two probes
  /// combined (2s + 5s) still fit inside one 10s health tick.
  static const controlProbeTimeout = Duration(seconds: 5);

  /// Grace after a server-truth-confirmed cold restore during which a
  /// `disconnected` stage event is ignored. A fresh engine re-attach
  /// reports no running tunnels even when the OS TUN survived, so the
  /// stage stream replays the same lie right after the confirm — honoring
  /// it would flip a just-restored session to idle and orphan the live
  /// native tunnel. Health ticks and status polls remain the corroboration
  /// for a truly dead tunnel.
  static const coldRestoreGrace = Duration(seconds: 5);
}
