import 'package:flutter/material.dart';

import '../../../../l10n/gen/app_localizations.dart';
import '../../data/models.dart';

/// Quick Connect row: dials the lowest-load region with capacity.
class QuickConnectTile extends StatelessWidget {
  const QuickConnectTile({
    super.key,
    required this.best,
    required this.busy,
    required this.selected,
    required this.onTap,
  });

  final Region? best;
  final bool busy;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.bolt),
      title: Text(l10n.regionsQuickConnect),
      subtitle: Text(
        best == null
            ? l10n.regionsNoCapacity
            : l10n.regionsLowestLoad(best!.name),
      ),
      enabled: !busy && best != null,
      selected: selected,
      onTap: best == null ? null : onTap,
    );
  }
}

/// One region with its servers. Regions with `servers: []` have no dialable
/// capacity and render disabled.
class RegionExpansionTile extends StatelessWidget {
  const RegionExpansionTile({
    super.key,
    required this.region,
    required this.load,
    required this.busy,
    required this.selectedServerId,
    required this.onServerTap,
  });

  final Region region;
  final int load;
  final bool busy;
  final String? selectedServerId;
  final void Function(String serverId) onServerTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ExpansionTile(
      title: Text(region.name),
      subtitle: Text(
        region.hasCapacity
            ? l10n.regionsServerCount(region.servers.length, load)
            : l10n.regionsNoCapacity,
      ),
      enabled: !busy && region.hasCapacity,
      children: [
        for (final s in region.servers)
          ListTile(
            title: Text(s.name),
            subtitle: Text(
              l10n.regionsServerSubtitle(s.endpoint, s.wgPort, s.activePeers),
            ),
            enabled: !busy,
            selected: selectedServerId == s.id,
            trailing: selectedServerId == s.id ? const Icon(Icons.check) : null,
            onTap: busy ? null : () => onServerTap(s.id),
          ),
      ],
    );
  }
}
