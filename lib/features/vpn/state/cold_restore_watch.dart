/// Cold-restore watch (see `reconcileColdStart`): whether an unconfirmed
/// optimistic/working restore is waiting on the stage stream ([armed]).
/// Held as its own cohort so the arm/disarm transitions live in one place.
class ColdRestoreWatch {
  /// True while an unconfirmed restore waits on the stage stream: a later
  /// `connected` event retries the confirm, a terminal event falls back to
  /// idle. Cleared by any fresh tunnel start, explicit teardown, or
  /// confirmed restore.
  bool armed = false;

  /// Disarms the watch. Used by fresh tunnel starts, explicit teardowns,
  /// and session resets.
  void clear() {
    armed = false;
  }
}
