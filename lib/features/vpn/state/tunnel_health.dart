/// Anchors describing the **current tunnel generation**: the tunnel-start
/// clock, whether the last status request was answered by the control plane,
/// and the consecutive performed-dead gateway-echo run.
///
/// Deliberately kept out of [ConnState]: these are sensors read by the
/// handshake and echo policy, never rendered, and a raw `ConnState(...)`
/// reset (session end, forget-device, auth revocation) must not be able to
/// zero them by accident. Bundling them here gives the cohort one owner and
/// one reset ([reset] / [start]) so the arm/clear transitions cannot drift
/// apart — the pairing that used to be a `_resetLocalHealth()` call sitting
/// immediately next to a bare `_connectedAt = now` write.
class TunnelHealth {
  /// When the current tunnel (re)started, anchoring the never-handshook branch
  /// of `isHandshakeStale`: a supported reader's null *before* the grace
  /// window is "too slow to tell", past it is "never answered". Null whenever
  /// no tunnel generation is anchored (a start that never completed, or the
  /// anchors were dropped).
  DateTime? connectedAt;

  /// True when the most recent status request was *rejected* by the control
  /// plane (401/403/409/429/5xx). Such a response still proves the control
  /// plane was reachable, so health must not reinterpret it as a transport
  /// outage. A successful poll clears it and reaches the same conclusion the
  /// other way, through `ConnState.lastStatusAt` + `pollFailures: 0`.
  bool statusAnswered = false;

  /// Consecutive health ticks whose in-tunnel gateway echo was
  /// *performed-dead* (`false`, never null). Reaching
  /// `ConnectionTuning.echoStallStrikes` shortens the dead-peer handshake
  /// window to `echoStallHandshakeAge`; any alive/unknown echo clears the run.
  int deadEchoStrikes = 0;

  /// Anchors a fresh tunnel generation: drops the previous generation's
  /// evidence and sets the start clock in one step, so the reset and the
  /// anchor cannot be split by an intervening write.
  void start(DateTime now) {
    connectedAt = now;
    statusAnswered = false;
    deadEchoStrikes = 0;
  }

  /// Drops every anchor because the tunnel they describe is gone. The policy
  /// reads each as "unknown" until the next [start].
  void reset() {
    connectedAt = null;
    statusAnswered = false;
    deadEchoStrikes = 0;
  }

  /// Records one gateway-echo observation: `false` (performed-dead)
  /// increments the run, while `true` (alive) and `null` (skipped/unknown)
  /// clear it.
  void observeEcho(bool? alive) {
    deadEchoStrikes = alive == false ? deadEchoStrikes + 1 : 0;
  }
}
