import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../data/models.dart';
import '../domain/backend_issue.dart';

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

    /// Consecutive transient status-poll failures (network/timeout only),
    /// saturating at [ConnectionTuning.maxPollFailures] — every reader
    /// thresholds it, so a longer outage carries no extra information.
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

    /// Structured cause of the last backend interaction failure while
    /// connected, if any (null when healthy). [healthNote] carries the
    /// human-facing text; this carries the machine-readable distinction the
    /// UI uses to separate "authentication expired" from "network
    /// unreachable" (see `domain/backend_issue.dart`).
    BackendIssue? backendIssue,

    /// True when the last explicit user operation (switch / Quick Connect)
    /// failed. Set by the shared failure surfacing and cleared when a new
    /// operation starts, so the UI can decide whether [message] warrants a
    /// snack without parsing its (localizable, controller-owned) wording.
    @Default(false) bool opFailed,

    /// Auto-heal restarts for the current failure incident. At most one
    /// cached-tunnel restart is attempted for ambiguous stalls; positive
    /// dead-path evidence can skip it and go straight to failover. The counter
    /// is cleared by a healthy status poll or a fresh session.
    @Default(0) int autoHealAttempts,

    /// Automatic dead-server moves for this connected session. Incremented
    /// on failover once the same-server heal is spent; capped by the
    /// controller's max so two dead servers can't ping-pong forever.
    /// Reset on manual connect/switch, disconnect, and a successful status
    /// poll that lands on a *healthy* tunnel path (an observed, fresh
    /// handshake): a status response while the WireGuard path stays dead is
    /// not the outage ending, so it must not restore the ladder.
    @Default(0) int autoFailoverAttempts,

    /// The backend reported the serving node as not `online` on the last
    /// `GET …/server-status` poll (see [ServerStatus.isUnhealthy]).
    ///
    /// Unlike every other signal in this snapshot this one is *attributed*:
    /// it says the node itself is gone, not merely that the local path looks
    /// dead. It therefore counts as positive path-dead evidence and skips the
    /// same-server heal cycle on the way to a move — redialing a node the
    /// backend has already given up on only spends the budget.
    ///
    /// False while the read is unknown (never polled, or the request failed):
    /// absence of evidence is never evidence of death, so the local
    /// echo/handshake ladder keeps owning that case unchanged.
    @Default(false) bool serverConfirmedDown,
  }) = _ConnState;
}
