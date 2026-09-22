import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import 'control_probe.dart';
import 'network_monitor.dart';

/// Reachability of the control plane while disconnected.
///
/// Fail-open by design: [unknown] (loopback API, errored probe) never
/// disables Connect — it only means "no evidence of an outage". Only a
/// corroborated [unreachable] (no OS link, or the `/health` probe got no
/// HTTP response at all) hard-disables the Home connect button.
enum BackendHealth { reachable, unreachable, unknown }

/// Pure classifier so the layering stays unit-testable without I/O.
BackendHealth classifyBackendHealth({
  required bool hasLink,
  required bool? apiReachable,
}) {
  if (!hasLink) return BackendHealth.unreachable;
  return switch (apiReachable) {
    true => BackendHealth.reachable,
    false => BackendHealth.unreachable,
    null => BackendHealth.unknown,
  };
}

/// Re-check cadence for [backendHealthProvider]. The probe is an
/// unauthenticated `GET /health` outside the session rate limiter, so it
/// may run an order of magnitude faster than the 60s authenticated status
/// poll.
const backendHealthPollInterval = Duration(seconds: 15);

/// Single health read shared by the polling provider below. Fail-open:
/// a broken link plugin reports online and a throwing probe reports
/// unknown, so neither can wedge the Home button disabled forever.
Future<BackendHealth> readBackendHealth(
  NetworkMonitor monitor,
  ControlPlaneProbe probe,
) async {
  final bool hasLink;
  try {
    hasLink = await monitor.hasLink();
  } catch (e) {
    AppLog.error('backend health link read failed (assuming online)', e);
    return BackendHealth.unknown;
  }
  if (!hasLink) return BackendHealth.unreachable;
  try {
    return classifyBackendHealth(
      hasLink: true,
      apiReachable: await probe.check(),
    );
  } catch (e) {
    AppLog.error('backend health probe failed', e);
    return BackendHealth.unknown;
  }
}

/// Continuously polled control-plane reachability for the disconnected Home.
///
/// A `StreamProvider.autoDispose`: the poll loop lives exactly as long as
/// something watches it (the Home power button/banner). Navigating away
/// disposes the subscription and stops the timers — no polling while on
/// Regions/Settings or while connected (the connected tunnel has its own
/// status/health ticks). Emits immediately on subscribe, then every
/// [backendHealthPollInterval].
final backendHealthProvider = StreamProvider.autoDispose<BackendHealth>((
  ref,
) async* {
  final monitor = ref.watch(networkMonitorProvider);
  final probe = ref.watch(controlPlaneProbeProvider);
  var alive = true;
  ref.onDispose(() => alive = false);
  yield await readBackendHealth(monitor, probe);
  while (alive) {
    await Future<void>.delayed(backendHealthPollInterval);
    if (!alive) break;
    yield await readBackendHealth(monitor, probe);
  }
});
