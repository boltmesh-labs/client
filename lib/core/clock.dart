/// Injectable wall clock.
///
/// The connection state machine has several time-dependent windows (handshake
/// staleness, backend quiet, cold-restore grace) that tests must age
/// deterministically instead of sleeping or poking private anchors. Reading
/// the time through this seam keeps those windows testable without a
/// `@visibleForTesting` date field per anchor.
abstract interface class Clock {
  DateTime now();
}

/// Production [Clock] backed by [DateTime.now].
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
