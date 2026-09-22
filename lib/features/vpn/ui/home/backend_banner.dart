import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../data/backend_health.dart';
import '../../state/vpn_providers.dart';

/// Backend-unreachable banner for the disconnected Home.
///
/// Visible only while `idle`/`error` and the control-plane poll reports
/// [BackendHealth.unreachable]. Loading/error/unknown fail open (no banner)
/// so a slow first probe never flashes.
class BackendBanner extends ConsumerWidget {
  const BackendBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(connectionProvider.select((c) => c.phase));
    if (phase != ConnPhase.idle && phase != ConnPhase.error) {
      return const SizedBox.shrink();
    }
    final health = ref.watch(backendHealthProvider).value;
    if (health != BackendHealth.unreachable) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        liveRegion: true,
        label: l10n.homeBackendUnreachable,
        child: ExcludeSemantics(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.homeBackendUnreachable,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
