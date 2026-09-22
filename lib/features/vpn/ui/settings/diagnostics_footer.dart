import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/env.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../data/platform_info.dart';
import '../../domain/tunnel_policy.dart';
import '../../state/vpn_providers.dart';

/// Diagnostics footer: API/platform line, live tunnel snapshot, and the
/// loopback-API warning. Watches only the debug slice.
///
/// The snapshot is debug-only (in release it is noise) and intentionally
/// *not* a live region: the status age and traffic counters change on every
/// tick, so announcing them would make a screen reader talk continuously.
/// Meaningful tunnel transitions are already announced by the Home
/// header/banner.
class DiagnosticsFooter extends ConsumerWidget {
  const DiagnosticsFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loopback = Env.isLoopbackApi;
    if (!kDebugMode && !loopback) return const SizedBox.shrink();

    final conn = ref.watch(
      connectionProvider.select(
        (c) => (
          c.lastStage,
          c.lastStatusAt,
          c.pollFailures,
          c.rxBytes,
          c.txBytes,
          c.healthNote,
          c.backendIssue,
        ),
      ),
    );
    final l10n = AppLocalizations.of(context);
    final lastStatusAt = conn.$2;
    final stage = conn.$1?.name ?? l10n.settingsDiagnosticsUnknown;
    final last = lastStatusAt == null
        ? l10n.settingsDiagnosticsNever
        : l10n.settingsDiagnosticsAgo(
            DateTime.now().difference(lastStatusAt).inSeconds,
          );
    final traffic = conn.$4 == null && conn.$5 == null
        ? null
        : l10n.settingsTrafficLabel(
            formatBytesOrDash(conn.$4),
            formatBytesOrDash(conn.$5),
          );
    final note = conn.$6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kDebugMode) ...[
          Text(
            l10n.settingsDiagnosticsApi(Env.apiBaseUrl, currentPlatformLabel()),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.settingsDiagnosticsTunnel(stage, last, conn.$3),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (traffic != null)
            Text(traffic, style: Theme.of(context).textTheme.bodySmall),
          if (note != null && note.isNotEmpty)
            Text(note, style: Theme.of(context).textTheme.bodySmall),
          // The structured backend cause, distinct from the free-text note:
          // separates "auth expired" from "unreachable" even when a
          // stage-driven note owns the banner.
          if (conn.$7 != null)
            Text(
              l10n.settingsDiagnosticsBackend(conn.$7!.name),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
        if (loopback) ...[
          if (kDebugMode) const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.settingsLoopbackNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
