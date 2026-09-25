import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../state/vpn_providers.dart';

/// Split-tunnel preference tile. True (default) keeps LAN subnets off the
/// tunnel; false is the strict full-tunnel kill switch.
class LanSwitchTile extends ConsumerWidget {
  const LanSwitchTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pref = ref.watch(allowLocalProvider);
    final connected = ref.watch(
      connectionProvider.select((c) => c.phase == ConnPhase.connected),
    );
    final l10n = AppLocalizations.of(context);

    // While the saved value is unknown (loading) or unreadable (error), show
    // no Switch at all: a disabled Switch would still render a thumb position
    // and present the unknown as on/off. A non-interactive tile explains the
    // state instead.
    Widget unknownTile({required Widget trailing, required String subtitle}) =>
        ListTile(
          title: Text(l10n.settingsAllowLanTitle),
          subtitle: Text(subtitle),
          trailing: trailing,
          enabled: false,
        );

    return pref.when(
      loading: () => unknownTile(
        subtitle: l10n.settingsAllowLanLoading,
        trailing: Semantics(
          label: l10n.commonApplyingSetting,
          child: const ExcludeSemantics(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (_, _) => unknownTile(
        subtitle: l10n.settingsAllowLanError,
        trailing: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
      data: (allow) => SwitchListTile(
        title: Text(l10n.settingsAllowLanTitle),
        subtitle: Text(l10n.settingsAllowLanSubtitle),
        value: allow,
        onChanged: (v) async {
          // Capture the messenger before the await: the tile may be gone by
          // the time the restart resolves (Settings tab rebuilds).
          final messenger = ScaffoldMessenger.of(context);
          final applied = await ref
              .read(connectionProvider.notifier)
              .setAllowLocal(v);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                !applied
                    ? l10n.settingsAllowLanFailed
                    : connected
                    ? l10n.settingsAllowLanApplied
                    : l10n.settingsAllowLanSaved,
              ),
            ),
          );
        },
      ),
    );
  }
}
