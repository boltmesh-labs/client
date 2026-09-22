import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/log.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../../auth/state/auth_providers.dart';
import '../../state/vpn_providers.dart';

/// Signed-in identity + Log out. The tunnel tears down and the device is
/// released server-side first, while this screen is still mounted: logout
/// flips the auth gate, unmounting this screen and the tunnel controller
/// behind it. Releasing (not just disconnecting) frees the plan's device
/// slot so the next login can provision instead of hitting the limit.
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(
      authProvider.select((a) => a.value ?? const AuthState()),
    );
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.settingsSignedInAs(auth.username ?? l10n.settingsUnknownUser),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: auth.working
              ? null
              : () async {
                  // A failed device release must never trap the user in the
                  // signed-in screen: log it and finish the logout anyway.
                  try {
                    await ref.read(connectionProvider.notifier).releaseDevice();
                  } catch (e) {
                    AppLog.error('logout device release failed', e);
                  }
                  await ref.read(authProvider.notifier).logout();
                },
          child: Text(l10n.settingsLogOut),
        ),
      ],
    );
  }
}
