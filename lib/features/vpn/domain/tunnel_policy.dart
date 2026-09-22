import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

/// Pure tunnel-health policy extracted from [ConnectionController].
///
/// Kept free of Riverpod/timers/storage so it can be unit-tested in
/// isolation. Thresholds live with the controller; only the decision
/// functions live here.

/// Stages that mean the OS tunnel is alive but not passing traffic.
bool isDegradedStage(VpnStage s) =>
    s == VpnStage.noConnection ||
    s == VpnStage.reconnect ||
    s == VpnStage.waitingConnection;

/// Stages where the OS tunnel exists but the handshake isn't done. A cold
/// start seeing one must show "Restoring…" (working), never Connected: the
/// tunnel may still fail before it carries traffic. Overlaps [isDegradedStage]
/// deliberately (`reconnect`/`waitingConnection`): warm-connected they mean
/// "alive but stalled", cold they mean "not up yet".
bool isColdTransitionalStage(VpnStage s) =>
    s == VpnStage.connecting ||
    s == VpnStage.waitingConnection ||
    s == VpnStage.authenticating ||
    s == VpnStage.reconnect ||
    s == VpnStage.preparing;

/// Extracts an RX byte counter from `trafficStats()`. The plugin reports
/// `totalDownload`/`totalUpload` (+ `downloadSpeed`/`uploadSpeed` rates and
/// a `duration` string) on every OS, so rx-like keys are matched recursively
/// and `*speed*` rate keys are skipped (rates fluctuate and are not
/// cumulative counters). Null means unknown or no RX counter present
/// (never treated as a stall on its own).
int? extractRxBytes(Map<String, dynamic> stats) => _sumByKeys(stats, _isRxKey);

/// Extracts a TX byte counter from `trafficStats()`. Mirrors
/// [extractRxBytes]; `*speed*` rate keys are skipped. Null means unknown
/// or no TX counter present.
int? extractTxBytes(Map<String, dynamic> stats) => _sumByKeys(stats, _isTxKey);

bool _isRxKey(String k) =>
    k.contains('rx') ||
    k.contains('receiv') ||
    k.contains('download') ||
    k == 'in';

bool _isTxKey(String k) =>
    k.contains('tx') ||
    k.contains('transmit') ||
    k.contains('upload') ||
    k == 'out';

int? _sumByKeys(Map<String, dynamic> stats, bool Function(String) isKey) {
  // Prefer top-level totals when present: payloads often carry both a
  // `totalDownload` aggregate and per-peer `rx_bytes` for the same bytes,
  // and summing both double-counts. Only recurse when no top-level counter
  // matches.
  var topSum = 0;
  var topHit = false;
  for (final entry in stats.entries) {
    final v = entry.value;
    if (v is num) {
      final k = entry.key.toLowerCase();
      if (k.contains('speed')) continue;
      if (isKey(k)) {
        topSum += v.toInt();
        topHit = true;
      }
    }
  }
  if (topHit) return topSum;

  var hit = false;
  var sum = 0;
  void visit(Object? node, [String? key]) {
    if (node is num) {
      final k = key?.toLowerCase() ?? '';
      if (k.contains('speed')) return;
      if (isKey(k)) {
        sum += node.toInt();
        hit = true;
      }
    } else if (node is Map) {
      node.forEach((k, v) => visit(v, k.toString()));
    } else if (node is Iterable) {
      for (final v in node) {
        visit(v, key);
      }
    }
  }

  visit(stats);
  return hit ? sum : null;
}

/// Human-readable byte count for traffic counters (`0 B`, `1.5 KB`,
/// `12.4 MB`, …). Pure so it can be unit-tested without Riverpod.
/// Negative inputs are clamped to `0 B` (a counter must never go below 0).
String formatBytes(int bytes) {
  final clamped = bytes < 0 ? 0 : bytes;
  if (clamped < 1024) return '$clamped B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = clamped.toDouble() / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// [formatBytes] for an optional counter, or an em dash when the plugin
/// reported none (see `ConnState.rxBytes`/`txBytes`).
String formatBytesOrDash(int? bytes) =>
    bytes == null ? '—' : formatBytes(bytes);

/// Dead-peer signal from the last completed WireGuard handshake.
///
/// Unlike RX/TX byte counters this is unambiguous: handshakes complete every
/// ~2min on a live peer (plus keepalive-driven ones), so a handshake older
/// than [staleAfter] means the peer stopped answering — regardless of
/// whether the user is idle, uploading, or on truncated-KB counters.
///
/// No handshake observed ([lastHandshakeAt] null) is split by
/// [readerSupported]:
/// - Reader supported: null is *evidence* — the peer never answered a single
///   handshake initiation (the WireGuard core retries every 5s). Once the
///   tunnel has been up longer than [graceAfter] (a fraction of
///   [staleAfter]; a live peer handshakes within seconds), the peer is dead.
/// - Reader unsupported: null is *absence of evidence* (unreadable IPC, or
///   no native reader on this platform) and never counts as stale on its
///   own — the degraded-stage path still heals those platforms.
bool isHandshakeStale({
  required DateTime? lastHandshakeAt,
  required DateTime now,
  DateTime? connectedAt,
  bool readerSupported = true,
  Duration graceAfter = const Duration(seconds: 45),
  Duration staleAfter = const Duration(seconds: 150),
}) {
  final last = lastHandshakeAt;
  if (last != null) {
    // Future timestamps (clock skew) are fresh, never stale.
    return now.difference(last) >= staleAfter;
  }
  if (!readerSupported) return false;
  final since = connectedAt;
  if (since == null) return false;
  return now.difference(since) >= graceAfter;
}
