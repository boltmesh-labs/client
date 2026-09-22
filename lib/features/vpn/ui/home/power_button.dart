import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../data/backend_health.dart';
import '../../state/vpn_providers.dart';
import '../regions/switch_feedback.dart';

/// Hero power control: a big circular toggle with an explicit
/// Connect/Disconnect label (a bare Switch is poor affordance for a
/// destructive, slow network action), plus the working spinner.
///
/// Watches the phase plus the backend-health poll while disconnected, so
/// traffic/health updates don't repaint it. While
/// `idle`/`error`, a corroborated-unreachable control plane hard-disables
/// Connect: tapping it could only fail with the same outage. Loading or
/// unknown health fails open (button stays enabled).
class PowerButton extends ConsumerWidget {
  const PowerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final phase = ref.watch(connectionProvider.select((c) => c.phase));
    final ctl = ref.read(connectionProvider.notifier);
    final connected = phase == ConnPhase.connected;
    final working = phase == ConnPhase.working;
    final disconnected = phase == ConnPhase.idle || phase == ConnPhase.error;
    // Only watched while disconnected: the backend-health poll is for the
    // disconnected Home, and the connected tunnel already has its own
    // status/health ticks (see `data/backend_health.dart`). Watching it
    // unconditionally polled `GET /health` every 15s even while connected.
    final backendDown =
        disconnected &&
        ref.watch(backendHealthProvider).value == BackendHealth.unreachable;
    final disabled = working || backendDown;

    final powerLabel = connected ? l10n.homeDisconnect : l10n.homeConnect;
    final powerHint = connected
        ? l10n.homeDisconnectHint
        : l10n.homeConnectHint;
    final theme = Theme.of(context);
    final colors = boltMeshColorsOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          label: powerLabel,
          hint: powerHint,
          child: ExcludeSemantics(
            child: SizedBox(
              width: 168,
              height: 168,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  // Connected uses the semantic tunnel-up pair; the enabled
                  // foreground follows it so the label keeps AA contrast.
                  backgroundColor: connected
                      ? colors.connected
                      : theme.colorScheme.primary,
                  foregroundColor: connected
                      ? colors.onConnected
                      : theme.colorScheme.onPrimary,
                  disabledBackgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                ),
                onPressed: disabled
                    ? null
                    : () async {
                        // Disconnect tears the tunnel down locally no matter
                        // what the release POST answers, so it never snacks a
                        // failure. Connect surfaces `opFailed` (including a
                        // 429 countdown) so a tap is never silently dead.
                        if (connected) {
                          await ctl.disconnect();
                          return;
                        }
                        await ctl.quickConnect();
                        if (!context.mounted) return;
                        showSwitchFeedback(
                          context,
                          ref.read(connectionProvider),
                        );
                      },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.power_settings_new,
                      size: 56,
                      color: disabled
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      working ? l10n.homeWorking : powerLabel,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: disabled
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (working)
          Semantics(
            label: l10n.homeWorking,
            child: const ExcludeSemantics(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
