import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../domain/tunnel_policy.dart';
import '../../state/vpn_providers.dart';

/// Session traffic counters for the connected tunnel.
///
/// Watches only the counters + phase: status-poll metadata updates
/// (plan, health notes) don't repaint the card.
class TrafficCard extends ConsumerWidget {
  const TrafficCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final traffic = ref.watch(
      connectionProvider.select((c) => (c.phase, c.rxBytes, c.txBytes)),
    );
    final phase = traffic.$1;
    final rxBytes = traffic.$2;
    final txBytes = traffic.$3;
    final connected = phase == ConnPhase.connected;
    final working = phase == ConnPhase.working;

    final hasTraffic = rxBytes != null || txBytes != null;
    if (!hasTraffic || !(connected || working)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final downStr = formatBytesOrDash(rxBytes);
    final upStr = formatBytesOrDash(txBytes);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Semantics(
        label: l10n.homeTrafficSemantics(downStr, upStr),
        child: ExcludeSemantics(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.homeTrafficTitle,
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.homeTrafficLabel(downStr, upStr),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
