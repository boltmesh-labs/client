import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'settings/account_section.dart';
import 'settings/device_name_section.dart';
import 'settings/diagnostics_footer.dart';
import 'settings/forget_device_button.dart';
import 'settings/lan_switch_tile.dart';

/// Settings: account (sign out), device display name, split-tunnel
/// preference, device reset, and the diagnostics footer.
///
/// Each section is its own widget with a narrow provider slice so edits in
/// one section don't rebuild the others.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          AccountSection(),
          SizedBox(height: 24),
          DeviceNameSection(),
          SizedBox(height: 24),
          LanSwitchTile(),
          SizedBox(height: 24),
          ForgetDeviceButton(),
          SizedBox(height: 24),
          DiagnosticsFooter(),
        ],
      ),
    );
  }
}
