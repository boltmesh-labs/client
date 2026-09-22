import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/root_shell.dart';
import 'core/locale.dart';
import 'core/theme.dart';
import 'l10n/gen/app_localizations.dart';

void main() {
  runApp(const ProviderScope(child: BoltMeshApp()));
}

/// Composition root: localization, theming, and the auth gate. Screen and
/// lifecycle behavior live under `app/` and `features/`.
class BoltMeshApp extends StatelessWidget {
  const BoltMeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Localized OS/task-switcher title; a static `title:` cannot translate.
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: resolveAppLocale,
      theme: boltMeshTheme,
      darkTheme: boltMeshDarkTheme,
      home: const RootShell(),
    );
  }
}
