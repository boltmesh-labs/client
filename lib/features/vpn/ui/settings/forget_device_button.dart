import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        await ref.read(connectionProvider.notifier).forgetDevice();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.settingsDeviceCleared)));
      },
      child: Text(l10n.settingsForgetButton),
    );
  }
}
