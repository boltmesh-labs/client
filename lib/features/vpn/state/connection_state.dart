import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../data/models.dart';

part 'connection_state.freezed.dart';

enum ConnPhase { idle, working, connected, error }

@freezed
abstract class ConnState with _$ConnState {
  const factory ConnState({
    @Default(ConnPhase.idle) ConnPhase phase,
    @Default('') String message,
    DialParams? dial,
    String? regionId,
    String? serverId,
    // True when the pinned target came from an explicit user tap (Regions
    // tab server/region selection). Auto-picked Quick Connect targets leave
    // this false, so dead-server failover may still roam globally; an
    // explicit pin constrains failover to the selected region instead.
    @Default(false) bool explicitTarget,
    DeviceStatus? deviceStatus,
    DateTime? lastStatusAt,

    /// Consecutive transient status-poll failures (network/timeout only).
    /// Reset on any successful poll or fresh tunnel start.
    @Default(0) int pollFailures,

    /// Last observed native tunnel stage (null until first observation).
    VpnStage? lastStage,

    /// Last published traffic counters for the Home card (null until the
    /// first successful `trafficStats()` read with a usable counter, or
    /// when the plugin reports none).
    int? rxBytes,
    int? txBytes,

    /// Degraded-tunnel banner (backend unreachable or stage anomaly).
    /// Null when healthy.
    String? healthNote,

    /// True when the last explicit user operation (switch / Quick Connect)
    /// failed. Set by the shared failure surfacing and cleared when a new
    /// operation starts, so the UI can decide whether [message] warrants a
    /// snack without parsing its (localizable, controller-owned) wording.
    @Default(false) bool opFailed,

    /// Auto-heal restarts for this connected session. Retries on every
    /// corroborated stall (the health-tick cadence is the backoff), so a
    /// flaky tunnel recovers without user action — until the move budget is
    /// spent and the trailing retries are used up, at which point recovery
    /// surfaces an actionable error. Same reset points as
    /// [autoFailoverAttempts].
    @Default(0) int autoHealAttempts,

    /// Automatic dead-server moves for this connected session. Incremented
    /// on failover once the same-server heal is spent; capped by the
    /// controller's max so two dead servers can't ping-pong forever.
    /// Reset on manual connect/switch, disconnect, and a successful status
    /// poll that lands on a *healthy* tunnel path (an observed, fresh
    /// handshake): an out-of-band poll success while the WireGuard path stays
    /// dead is not the outage ending, so it must not restore the ladder.
    @Default(0) int autoFailoverAttempts,
  }) = _ConnState;
}
