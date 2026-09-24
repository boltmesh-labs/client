import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/log.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../state/vpn_providers.dart';

/// Forget-device action: stops the tunnel before dropping the device
/// identity so a live tunnel is never left running on a forgotten device.
class ForgetDeviceButton extends ConsumerWidget {
  const ForgetDeviceButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return OutlinedButton(
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final forget = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.settingsForgetTitle),
            content: Text(l10n.settingsForgetBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.settingsCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.settingsForget),
              ),
            ],
          ),
        );
        if (forget != true) return;
        final clearedMessage = l10n.settingsDeviceCleared;
        final failedMessage = l10n.settingsDeviceReleaseFailed;
        try {
          await ref.read(connectionProvider.notifier).forgetDevice();
        } catch (e) {
          AppLog.error('forget device failed', e);
          messenger.showSnackBar(SnackBar(content: Text(failedMessage)));
          return;
        }
        messenger.showSnackBar(SnackBar(content: Text(clearedMessage)));
      },
      child: Text(l10n.settingsForgetButton),
    );
  }
}
