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
  /// automated hard-kill retry fires (same budget) without user input.
  static const stopTimeout = Duration(seconds: 3);
}
