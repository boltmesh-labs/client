import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../auth/state/auth_providers.dart';
import 'vpn_providers.dart';

/// Foreground lifecycle orchestration for the authenticated shell: the
/// first-frame provisioning + cold-start reconcile, the debounced resume
/// catch-up (auth first, then VPN), and the pause side that slows the
/// connected tunnel's background polling. Lives outside the widget so the
/// debounce and ordering are unit-testable without a widget tree.
///
/// No background timers/services of its own: on pause it only switches the
/// controller onto its slower cadence ([ConnectionController.setBackgrounded]),
/// and the native tunnel stays alive in kernel while suspended. On resume
/// the foreground cadence is restored first, then the health tick heals
/// locally, the status poll runs only when stale, and auth refreshes only
/// when expired.
class ResumeCoordinator {
  ResumeCoordinator(this._container);

  final ProviderContainer _container;

  /// Debounces rapid pause/resume flaps (lock/unlock) so one unlock never
  /// fires two catch-ups against the session-budgeted `status_limiter`.
  static const debounce = Duration(seconds: 3);
  DateTime? _lastCatchUp;

  /// First-frame startup: best-effort provisioning so the toggle works on
  /// first tap, then a cold-start reconcile with any surviving OS tunnel.
  ///
  /// Auth is re-checked at run time so a fast logout can never provision
  /// behind it (the auth restore itself already completed: the shell only
  /// mounts under `authenticated`). Failures only log.
  Future<void> onStartup() async {
    if (_container.read(authProvider).value?.status !=
        AuthStatus.authenticated) {
      return;
    }
    final ctl = _container.read(connectionProvider.notifier);
    try {
      await ctl.ensureProvisioned();
      // The OS tunnel survives a killed process while app state resets to
      // idle: reconcile with the live tunnel instead of showing a false
      // Disconnected (never restarts it — see reconcileColdStart).
      await ctl.reconcileColdStart();
    } catch (e) {
      AppLog.error('startup vpn restore', e);
    }
  }

  /// App hidden: slow the connected tunnel's background polling
  /// ([ConnectionController.setBackgrounded]). Auth-gated like every other
  /// VPN action; a no-op while not connected (the controller only restarts
  /// running timers).
  void onPause() {
    if (_container.read(authProvider).value?.status !=
        AuthStatus.authenticated) {
      return;
    }
    _container.read(connectionProvider.notifier).setBackgrounded(true);
  }

  /// Single resume entry point (auth, then VPN). Auth first: a revoked
  /// refresh signs out, and the connection controller's auth listener then
  /// tears down any orphaned tunnel. Best-effort throughout: failures only
  /// log, the periodic timers + 401 interceptor remain the backstop.
  Future<void> onResume({DateTime? now}) async {
    now ??= _container.read(clockProvider).now();
    // Restore the foreground cadence before the debounce: a rapid pause/
    // resume flap must still wake polling up even when it skips the
    // catch-up below.
    _container.read(connectionProvider.notifier).setBackgrounded(false);
    final last = _lastCatchUp;
    if (last != null && now.difference(last) < debounce) return;
    _lastCatchUp = now;
    try {
      await _container.read(authProvider.notifier).refreshIfExpired(now: now);
    } catch (e) {
      AppLog.error('resume auth catch-up failed', e);
    }
    if (_container.read(authProvider).value?.status !=
        AuthStatus.authenticated) {
      return;
    }
    try {
      final ctl = _container.read(connectionProvider.notifier);
      if (_container.read(connectionProvider).phase == ConnPhase.idle) {
        // Fresh process (or a prior teardown) while the OS tunnel stayed
        // up: reconcile with the system instead of the connected-only
        // catch-up below (which would no-op on the reset idle state).
        await ctl.reconcileColdStart();
      } else {
        await ctl.catchUpOnResume(now: now);
      }
    } catch (e) {
      AppLog.error('resume vpn catch-up failed', e);
    }
  }
}
