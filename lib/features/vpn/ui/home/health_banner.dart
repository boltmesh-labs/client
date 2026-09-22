import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../domain/backend_issue.dart';
import '../../state/vpn_providers.dart';

/// Degraded-tunnel banner (backend unreachable, auth/subscription lapse, or
/// stage anomaly). Null when healthy; only visible while connected.
///
/// A specific [ConnState.healthNote] (no-network, degraded stage, transport
/// unreachable, backend error) wins; when none is set but a structured
/// [BackendIssue] is, its copy is shown, so an expired session is never
/// rendered as a generic network failure.
class HealthBanner extends ConsumerWidget {
  const HealthBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (note, issue) = ref.watch(
      connectionProvider.select(
        (c) => c.phase == ConnPhase.connected
            ? (c.healthNote, c.backendIssue)
            : (null, null),
      ),
    );
    final l10n = AppLocalizations.of(context);
    final text = (note != null && note.isNotEmpty)
        ? note
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

/// Banner copy for a structured [BackendIssue], or null when there is none.
String? _issueText(AppLocalizations l10n, BackendIssue? issue) =>
    switch (issue) {
      BackendIssue.unreachable => l10n.homeBackendUnreachableConnected,
      BackendIssue.authExpired => l10n.homeAuthExpired,
      BackendIssue.subscriptionInactive => l10n.homeSubscriptionInactive,
      BackendIssue.serverError => l10n.homeBackendError,
      null => null,
    };
