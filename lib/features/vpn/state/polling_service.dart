import 'dart:async';

import '../../../core/env.dart';
import '../../../core/log.dart';

/// Background tick scheduling for the connected tunnel.
///
/// Extracted from [ConnectionController] so timer lifecycle lives in one
/// place. This class only decides *when* ticks fire; *what* a tick does
/// stays with the controller (`pollStatusOnce` / `checkHealthOnce`).
/// The status interval stays >= 60s against the session-budgeted
/// `status_limiter`; the local health check is backend-free and may run
/// faster. While the app is hidden the health tick slows to
/// [backgroundHealthCheckInterval] so a surviving tunnel keeps healing
/// without the foreground wake rate.
class PollingService {
  PollingService({
    Duration? statusInterval,
    Duration? healthInterval,
    Duration? statusInitialDelay,
    Duration? backgroundHealthInterval,
  }) : statusInterval = statusInterval ?? Env.statusPollInterval,
       healthInterval = healthInterval ?? healthCheckInterval,
       statusInitialDelay = statusInitialDelay ?? statusFirstPollDelay,
       backgroundHealthInterval =
           backgroundHealthInterval ?? backgroundHealthCheckInterval;

  final Duration statusInterval;
  final Duration healthInterval;

  /// Health-tick interval used while the app is hidden (see [start]'s
  /// `background`). Slower than [healthInterval] so a swiped-away tunnel
  /// still heals, but at a fraction of the wakeups.
  final Duration backgroundHealthInterval;

  /// One-off delay for the first status poll after (re)connect. The steady
  /// 60s cadence starts blind: an outage beginning right after connect
  /// waits a full interval before the first failure is even observed. One
  /// early check arms the heal → failover chain within ~15s of a
  /// hard server kill (this delay plus the failed request's own timeout);
  /// afterwards only the periodic timer fires. Well inside the 30/min
  /// session `status_limiter` budget (one extra request per connect). Every
  /// heal restart re-arms it via [start], which keeps corroboration flowing
  /// during an ongoing outage.
  static const statusFirstPollDelay = Duration(seconds: 5);

  /// Early one-shot delay actually used (injectable for tests).
  final Duration statusInitialDelay;

  /// Local health tick interval (backend status poll stays >= 60s).
  /// Backend-free (tunnel stage + handshake age), so it may run an
  /// order of magnitude faster than the status poll: a dead peer is
  /// detected on the next tick after its handshake goes stale instead
  /// of minutes.
  static const healthCheckInterval = Duration(seconds: 10);

  /// Background health tick (app hidden while a tunnel is up). Still well
  /// above the status-poll floor's two orders of magnitude, but 3× fewer
  /// wakeups than [healthCheckInterval]; the 3-strike echo path then
  /// confirms a dead data path in ~90s instead of ~30s, and a resume runs
  /// an immediate catch-up tick so returning to the foreground has no blind
  /// spot.
  static const backgroundHealthCheckInterval = Duration(seconds: 30);

  Timer? _statusTimer;
  Timer? _statusEarlyTimer;
  Timer? _healthTimer;
  final _statusBusy = _Flag();
  final _healthBusy = _Flag();

  /// (Re)starts both ticks plus the optional one-off early status check.
  /// Only the connected tunnel needs them: every other phase stops them.
  /// Restart-safe: any running timers are cancelled first. Ticks are
  /// single-flight: a slow tick skips until the in-flight one finishes, so
  /// overlapping `GET …/status` calls can never double-spend the session
  /// budget or double-increment rotation counters. The early check shares
  /// the status single-flight flag with the periodic timer.
  ///
  /// [background] selects the slower health cadence while the app is
  /// hidden; [earlyStatus] false suppresses the one-off early check (used
  /// on lifecycle restarts, where the resume catch-up already polls, and
  /// in the background, where it would only add a wakeup).
  void start({
    required Future<void> Function() onStatus,
    required Future<void> Function() onHealth,
    bool background = false,
    bool earlyStatus = true,
  }) {
    stop();
    if (earlyStatus) {
      _statusEarlyTimer = Timer(
        statusInitialDelay,
        () => _singleFlight(_statusBusy, onStatus, 'status poll'),
      );
    }
    _statusTimer = Timer.periodic(
      statusInterval,
      (_) => _singleFlight(_statusBusy, onStatus, 'status poll'),
    );
    _healthTimer = Timer.periodic(
      background ? backgroundHealthInterval : healthInterval,
      (_) => _singleFlight(_healthBusy, onHealth, 'health check'),
    );
  }

  /// Single-flight tick body: while one call is in flight, later ticks return
  /// immediately. Overlapping `GET …/status` calls could otherwise
  /// double-spend the session budget and double-count rotation ticks. The
  /// early status check shares [busy] with the periodic status timer.
  Future<void> _singleFlight(
    _Flag busy,
    Future<void> Function() tick,
    String label,
  ) async {
    if (busy.value) return;
    busy.value = true;
    try {
      await tick();
    } catch (e) {
      AppLog.error(label, e);
    } finally {
      busy.value = false;
    }
  }

  /// Cancels the timers. The single-flight flags are deliberately NOT reset
  /// here: [start] calls this first, and clearing a flag while its tick is
  /// still awaiting would let the restarted timer run a second tick
  /// concurrently with the in-flight one, defeating the single-flight
  /// guarantee. The `finally` in [_singleFlight] is the only writer that
  /// clears a flag, so a tick skipped across a restart is simply dropped.
  void stop() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _statusEarlyTimer?.cancel();
    _statusEarlyTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  bool get isRunning =>
      _statusTimer != null || _statusEarlyTimer != null || _healthTimer != null;
}

/// Mutable single-flight flag, shared by a timer and [PollingService.stop].
class _Flag {
  bool value = false;
}
