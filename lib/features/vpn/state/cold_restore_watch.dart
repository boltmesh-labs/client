import 'connection_tuning.dart';

/// Cold-restore watch (see `reconcileColdStart`): whether an unconfirmed
/// optimistic/working restore is waiting on the stage stream ([armed]) and
/// when server truth last confirmed a restore ([confirmedAt]). Bundles the
/// pair so the arm/disarm/confirm transitions and the post-restore grace
/// live in one place.
class ColdRestoreWatch {
  /// True while an unconfirmed restore waits on the stage stream: a later
  /// `connected` event retries the confirm, a terminal event falls back to
  /// idle. Cleared by any fresh tunnel start, explicit teardown, or
  /// confirmed restore.
  bool armed = false;

  /// When server truth last confirmed a cold restore (`GET …/config` ok).
  /// Anchors the post-restore grace: a fresh engine re-attach replays a
  /// lying `disconnected` event right after the confirm, which must not tear
  /// down the just-restored session.
  DateTime? confirmedAt;

  /// Disarms the watch and drops the grace anchor. Used by fresh tunnel
  /// starts, explicit teardowns, and session resets.
  void clear() {
    armed = false;
    confirmedAt = null;
  }

  /// True while a freshly confirmed restore is inside
  /// [ConnectionTuning.coldRestoreGrace], so a replayed `disconnected`/
  /// `denied` stage must be ignored.
  bool inGrace(DateTime now) =>
      confirmedAt != null &&
      now.difference(confirmedAt!) < ConnectionTuning.coldRestoreGrace;
}
