import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/vpn_providers.dart';

/// Degraded-tunnel banner (backend unreachable or stage anomaly).
/// Null when healthy; only visible while connected and idle.
class HealthBanner extends ConsumerWidget {
  const HealthBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(
      connectionProvider.select(
        (c) => c.phase == ConnPhase.connected ? c.healthNote : null,
      ),
    );
    if (note == null || note.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        liveRegion: true,
        label: note,
        child: ExcludeSemantics(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(note, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
