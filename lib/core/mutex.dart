import 'dart:async';

import 'log.dart';

/// Minimal FIFO async mutex.
///
/// Serializes tunnel ops (connect/switch/disconnect/...) so two `startVpn`
/// calls can never interleave on Windows (Wintun) and wedge the default
/// route. Unlike the previous `_busy` flag, waiters queue instead of being
/// silently dropped — a Disconnect tapped during Connect still runs.
///
/// Non-reentrant: an op holding the mutex must release before awaiting
/// another mutex-guarded op (see the provision+connect handover in
/// `switchServer`). Slots always complete normally, so [acquire] never
/// throws.
class AsyncMutex {
  Future<void>? _tail;

  bool get isLocked => _tail != null;

  /// Waits for the current holder (if any), then returns a one-shot
  /// `release` callback. Unlocked path completes synchronously.
  Future<void Function()> acquire([String op = 'op']) {
    final prev = _tail;
    final done = Completer<void>();
    // Chain synchronously to preserve FIFO order.
    _tail = done.future;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      if (identical(_tail, done.future)) _tail = null;
      done.complete();
    }

    if (prev == null) return Future.value(release);
    AppLog.info('$op waiting for previous operation');
    return prev.then((_) => release);
  }
}
