/// Shared native-tunnel timeouts for the [TunnelAdapter] implementations.
///
/// Both the `wireguard_flutter_plus` adapter and the Linux `boltmeshd` adapter
/// must present identical budgets to the controller, so the values live here
/// instead of being duplicated per adapter.
abstract final class TunnelTuning {
  /// Bound for native tunnel starts/reads; a wedged driver must never hang
  /// the UI in `working` forever.
  static const opTimeout = Duration(seconds: 10);

  /// Bound for health-tick reads (`stage()`/`trafficStats()`/handshake).
  /// Shorter than [opTimeout]: a wedged driver reports null (unknown, never a
  /// stall on its own) instead of stalling detection past the next tick.
  static const healthTimeout = Duration(seconds: 3);

  /// Bound for native tunnel stops. Graceful teardown gets this long, then an
  /// automated hard-kill retry fires without user input. The plugin adapter
  /// uses the same budget; the helper uses [helperStopRetryTimeout] for the
  /// retry so it can wait out daemon cleanup.
  static const stopTimeout = Duration(seconds: 3);

  /// Client exchange budget for a privileged helper operation. It covers the
  /// daemon's command plus bounded failure cleanup, and is intentionally
  /// longer than the shared plugin [opTimeout].
  static const helperOpTimeout = Duration(seconds: 45);

  /// A stop retry may have to wait for a canceled operation's manager gate to
  /// release before it can run. Keep the second attempt bounded separately
  /// from the first three-second cancellation deadline.
  static const helperStopRetryTimeout = Duration(seconds: 10);
}
