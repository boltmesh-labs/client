import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../domain/backend_issue.dart';
import '../../state/vpn_providers.dart';

/// Degraded-tunnel banner (backend unreachable, auth/subscription lapse,
/// serving node offline, or stage anomaly). Active recovery steps also render
/// while the controller is working through a restart or server move.
///
/// Structured recovery progress is localized here; otherwise a specific
/// [ConnState.healthNote] wins, followed by the structured [BackendIssue].
class HealthBanner extends ConsumerWidget {
  const HealthBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (note, issue, serverDown, action, reason) = ref.watch(
      connectionProvider.select(
        (c) => c.phase == ConnPhase.connected || c.phase == ConnPhase.working
            ? (
                c.healthNote,
                c.backendIssue,
                c.serverConfirmedDown,
                c.recoveryAction,
                c.recoveryReason,
              )
            : (null, null, false, null, null),
      ),
    );
    final l10n = AppLocalizations.of(context);
    // The serving node is down, and no more specific note explains it: the
    // backend attributed the failure, which no local probe can do, so say so
    // instead of rendering it as a generic stall.
    final authIssue =
        issue == BackendIssue.authExpired ||
        issue == BackendIssue.subscriptionInactive;
    final text = authIssue
        ? _issueText(l10n, issue)
        : action != null
        ? _recoveryText(l10n, action, reason)
        : (note != null && note.isNotEmpty)
        ? note
        : serverDown
        ? l10n.homeServerOffline
        : _issueText(l10n, issue);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        liveRegion: true,
        label: text,
        child: ExcludeSemantics(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(text, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}

String _recoveryText(
  AppLocalizations l10n,
  RecoveryAction action,
  RecoveryReason? reason,
) {
  final cause = switch (reason ?? RecoveryReason.unknown) {
    RecoveryReason.staleHandshake => l10n.homeRecoveryReasonHandshake,
    RecoveryReason.gatewayUnreachable => l10n.homeRecoveryReasonGateway,
    RecoveryReason.serverOffline => l10n.homeRecoveryReasonServerOffline,
    RecoveryReason.degradedTunnel => l10n.homeRecoveryReasonDegraded,
    RecoveryReason.noNetwork => l10n.homeRecoveryReasonNoNetwork,
    RecoveryReason.controlPlaneUnavailable =>
      l10n.homeRecoveryReasonControlPlane,
    RecoveryReason.deviceIdentityUnavailable =>
      l10n.homeRecoveryReasonDeviceIdentity,
    RecoveryReason.rateLimited => l10n.homeRecoveryReasonRateLimited,
    RecoveryReason.noAlternativeServer => l10n.homeRecoveryReasonNoAlternative,
    RecoveryReason.cheaperTransportUnresponsive =>
      l10n.homeRecoveryReasonTransportProbe,
    RecoveryReason.stableSessionProbe => l10n.homeRecoveryReasonStableProbe,
    RecoveryReason.unknown => l10n.homeRecoveryReasonUnknown,
  };
  return switch (action) {
    RecoveryAction.checking => l10n.homeRecoveryChecking(cause),
    RecoveryAction.restarting => l10n.homeRecoveryRestarting(cause),
    RecoveryAction.tryingNative => l10n.homeRecoveryTryingNative(cause),
    RecoveryAction.tryingAwg => l10n.homeRecoveryTryingAwg(cause),
    RecoveryAction.tryingStream => l10n.homeRecoveryTryingStream(cause),
    RecoveryAction.switchingServer => l10n.homeRecoverySwitchingServer(cause),
    RecoveryAction.waiting => l10n.homeRecoveryWaiting(cause),
  };
}

/// Banner copy for a structured [BackendIssue], or null when there is none.
String? _issueText(AppLocalizations l10n, BackendIssue? issue) =>
    switch (issue) {
      BackendIssue.unreachable => l10n.homeBackendUnreachableConnected,
      BackendIssue.authExpired => l10n.homeAuthExpired,
      BackendIssue.subscriptionInactive => l10n.homeSubscriptionInactive,
      BackendIssue.serverError => l10n.homeBackendError,
      null => null,
    };
