/// Tunables for [ConnectionController] health/rotation behavior.
///
/// One home for the numbers previously scattered as `static const`s on the
/// controller, so tests and docs quote a single source. The pure predicates
/// live in `domain/` (failover/tunnel policy); only the values live here.
abstract final class ConnectionTuning {
  /// Status-poll failures before the UI shows a degraded banner.
  static const degradedPollThreshold = 3;

  /// Ceiling for [ConnState.pollFailures]. Derived from
  /// [degradedPollThreshold] rather than a separate literal: the counter
  /// saturates exactly where its last consumer flips, so retuning the
  /// threshold cannot leave the ceiling behind. Every reader thresholds it
  /// (`>= 1` for corroboration, `>= degradedPollThreshold` for the banner),
  /// so nothing above the ceiling carries information — see
  /// `conn_poll.dart`.
  static const maxPollFailures = degradedPollThreshold;

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
  ///
  /// Two roles, both of them about acting *cheaply*. It is the corroboration
  /// gate for detecting a stall, and it is the never-handshook threshold at
  /// which the ladder may change transport — a rung step is a cheap same-server
  /// restart, so it is licensed on this local evidence alone (see
  /// `ladder_policy.dart`); the *move* keeps its later uncorroborated ceiling.
  /// A peer that has not completed a handshake in six retry
  /// intervals is not slow, and there is nothing for it to be idle about.
  ///
  /// It is deliberately *not* enough for an uncorroborated server move; that
  /// spends the move budget and stops the tunnel without asking anyone, so it
  /// waits for the later [hardFirstHandshakeCeiling]. Neither window is gated
  /// on a recovery restart having happened: both measure from the tunnel-start
  /// anchor, which every start resets — a restart moves the window rather than
  /// suspending it, and gating it would make the first connect after a
  /// long-idle client wait longer for a diagnosis than one that just restarted.
  static const firstHandshakeGrace = Duration(seconds: 30);

  /// Observed-handshake age past which a stale handshake acts *without*
  /// backend corroboration. The standard [handshakeStaleAfter] still needs a
  /// poll failure or a quiet backend, which a reachable out-of-band control
  /// plane never provides (WG UDP blocked while the API stays up). Local echo
  /// confirmation now handles the earlier restart path; this ceiling remains
  /// the deterministic fallback when the echo cannot be performed.
  /// The bypass only *enters* the stall; hard-stale is itself positive local
  /// path-death evidence, so failover can stop the tunnel before testing the
  /// control plane.
  static const hardHandshakeStaleAfter = Duration(seconds: 180);

  /// Never-handshook ceiling for a *supported* reader: the point at which
  /// "no handshake yet" is read as positive path-death evidence *without* any
  /// corroboration — no backend poll failure, no quiet-backend slow track, no
  /// control-plane probe.
  ///
  /// This is the deliberately higher bar for the one action that needs no
  /// corroboration to be safe enough: a fast-track server move stops the tunnel
  /// and spends the move budget on local evidence alone, because the control
  /// probe shares OS routes with the path that just died and would only fail
  /// through it. 45s (≈9 WireGuard retries) is ample even on a slow link, and
  /// still short enough that a filtered first connect is diagnosed well inside
  /// a minute. Compare [firstHandshakeGrace], which is enough for the cheap
  /// actions — detection, and a rung step.
  ///
  /// Independent of recovery restarts by construction: this measures from the
  /// tunnel-start anchor (`connectedAt`), which every start resets. An earlier
  /// version of this comment claimed it applied only "once a recovery restart
  /// had happened"; it never did, and the code has no way to know. What a
  /// restart does is move the window forward — a fresh tunnel has not
  /// handshaked yet, so its clock starts over, which is the intent.
  static const hardFirstHandshakeCeiling = Duration(seconds: 45);

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

  /// Same-server restarts allowed per failure incident, and so the number of
  /// rung steps one incident can buy (see `ladder_policy.dart`).
  ///
  /// Two, because a dual-format node serves two rungs below its floor and the
  /// two are different causes: a middlebox that fingerprints WireGuard blocks
  /// `native` and `awg` together but has no reason to touch a TLS session, so a
  /// walk that stopped after one step would move servers on a network where the
  /// rung that would have worked was never tried. It is the *walk* that is
  /// bounded, not the retries — a heal with nothing below spends itself on the
  /// current rung exactly as before.
  ///
  /// The ladder length is what bounds this in practice: the step is always the
  /// next advertised entry, so a node serving one rung below the floor gets one
  /// step and no more, and once the bottom rung is reached the same confirmed
  /// dead-path evidence moves servers instead.
  static const maxHealsPerIncident = 2;

  /// Automatic server moves per connected session. Bounds ping-ponging
  /// while two servers are down; the health-tick cadence is the backoff.
  static const maxAutoFailovers = 3;

  /// Same-server restarts allowed *after* the move budget is spent. A single
  /// bounded retry covers a local/native tunnel wedge; another health tick
  /// must wait for the control plane or surface an actionable error instead of
  /// restarting a proven-dead config forever (see
  /// [ConnectionRecovery._surfaceRecoveryExhausted]).
  ///
  /// Deliberately *not* [maxHealsPerIncident]: once there is nowhere to move,
  /// the second rung is no longer a cheap alternative to a move but just another
  /// restart of a path that is already proven dead.
  static const maxHealsAfterMoveBudget = 1;

  /// Stable connected time before probing one cheaper transport rung. The
  /// probe is a controlled restart; a missing liveness confirmation within
  /// [rungPromotionProbeTimeout] rolls back to the previously working rung.
  static const rungPromotionHealthyFor = Duration(hours: 24);

  /// Maximum time to wait for liveness after probing a cheaper transport.
  static const rungPromotionProbeTimeout = Duration(seconds: 45);

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
