import 'package:flutter/material.dart';

import '../../../../l10n/gen/app_localizations.dart';

/// Region/server search box. Stateless: the query state lives with the
/// parent so a list rebuild never loses focus or the controller.
class RegionSearchField extends StatelessWidget {
  const RegionSearchField({
    super.key,
    required this.controller,
    required this.onQuery,
  });

  final TextEditingController controller;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: l10n.regionsSearchHint,
          prefixIcon: const Icon(Icons.search),
        ),
        onChanged: (v) => onQuery(v.trim().toLowerCase()),
      ),
    );
  }
}
