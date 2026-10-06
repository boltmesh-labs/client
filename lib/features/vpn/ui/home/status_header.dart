import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../state/vpn_providers.dart';

/// Status icon + headline + optional detail lines (message, plan).
///
/// The headline carries the state (and the server name when connected), so the
/// separate server/endpoint line is gone. A [ConnState.message] that only
/// restates the state word ("Connected", "Disconnected") is dropped rather than
/// rendered a second time; progress and error messages still render.
///
/// Rebuilds only when its slice changes: phase/message/dial/plan are one
/// record select, so traffic-counter ticks don't repaint the header.
class StatusHeader extends ConsumerWidget {
  const StatusHeader({super.key});

  /// Short plan/expiry line from the background status poll (`>=60s`).
  /// The date is locale-formatted (`DateFormat.yMd`); [localeName] must be
  /// the active `Localizations.localeOf(context).toString()`.
  static String statusLine(
    AppLocalizations l10n,
    String localeName,
    String? tier,
    DateTime? expiresAt,
  ) {
    final plan = (tier == null || tier.isEmpty) ? l10n.homePlanFallback : tier;
    if (expiresAt == null) return l10n.homePlanOnly(plan);
    final date = DateFormat.yMd(localeName).format(expiresAt.toLocal());
    return l10n.homePlanRenews(plan, date);
  }

  static String _statusText(
    AppLocalizations l10n,
    ConnPhase phase,
    String? serverName,
    bool connected,
  ) {
    if (connected) {
      if (serverName != null && serverName.isNotEmpty) {
        return l10n.homeStatusConnectedTo(serverName);
      }
      return l10n.homeStatusConnected;
    }
    if (phase == ConnPhase.error) {
      return l10n.homeStatusError;
    }
    return l10n.homeStatusDisconnected;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toString();
    final conn = ref.watch(
      connectionProvider.select(
        (c) => (c.phase, c.message, c.dial, c.deviceStatus),
      ),
    );
    final phase = conn.$1;
    final message = conn.$2;
    final dial = conn.$3;
    final deviceStatus = conn.$4;
    final connected = phase == ConnPhase.connected;
    final statusText = _statusText(l10n, phase, dial?.serverName, connected);
    // The controller reports the plain state word as `message` for the steady
    // connected/disconnected snapshots; the headline already says it, so drop
    // the duplicate line. Progress and error detail still render.
    final showMessage =
        message.isNotEmpty &&
        message != l10n.homeStatusConnected &&
        message != l10n.homeStatusDisconnected;
    final theme = Theme.of(context);
    final colors = boltMeshColorsOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          liveRegion: true,
          label: statusText,
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected ? Icons.vpn_lock : Icons.vpn_lock_outlined,
                  size: 72,
                  color: connected
                      ? colors.connected
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  statusText,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        if (showMessage) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            label: message,
            child: ExcludeSemantics(
              child: Text(message, textAlign: TextAlign.center),
            ),
          ),
        ],
        if (deviceStatus != null) ...[
          const SizedBox(height: 4),
          Text(
            statusLine(
              l10n,
              localeName,
              deviceStatus.tier,
              deviceStatus.subscriptionExpiresAt,
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
