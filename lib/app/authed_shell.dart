import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/vpn/state/resume_coordinator.dart';
import '../features/vpn/ui/home_screen.dart';
import '../features/vpn/ui/regions_screen.dart';
import '../features/vpn/ui/settings_screen.dart';
import '../l10n/gen/app_localizations.dart';

/// Authenticated shell: the three VPN tabs plus the app-lifecycle catch-up.
///
/// Mounted only under `authenticated` (see [RootShell]), so the tunnel
/// providers and their provisioning/discovery never race the session
/// restore. All startup/resume orchestration lives in [ResumeCoordinator];
/// this widget only wires the listener and the first-frame kickoff.
class AuthedShell extends ConsumerStatefulWidget {
  const AuthedShell({super.key});

  @override
  ConsumerState<AuthedShell> createState() => _AuthedShellState();
}

class _AuthedShellState extends ConsumerState<AuthedShell> {
  int _index = 0;
  AppLifecycleListener? _resumeListener;
  late final ResumeCoordinator _resume;

  @override
  void initState() {
    super.initState();
    // Foreground-only resume catch-up plus a pause side that slows the
    // connected tunnel's background polling (see ResumeCoordinator).
    _resume = ResumeCoordinator(
      ProviderScope.containerOf(context, listen: false),
    );
    _resumeListener = AppLifecycleListener(
      onResume: () => _resume.onResume(),
      onPause: _resume.onPause,
    );
    // Best-effort provisioning so the toggle works on first tap. Deferred
    // to the first frame (not a microtask) so a fast logout can't provision
    // behind it — the coordinator re-checks the auth status at run time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_resume.onStartup());
    });
  }

  @override
  void dispose() {
    _resumeListener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const pages = [HomeScreen(), RegionsScreen(), SettingsScreen()];
    return Scaffold(
      // IndexedStack keeps every tab mounted: switching tabs preserves the
      // Regions list/scroll and any text typed in Settings instead of
      // rebuilding (and refetching) from scratch. Only the selected child is
      // painted, so the hidden tabs cost nothing visible.
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.vpn_key),
            label: l10n.navConnect,
          ),
          NavigationDestination(
            icon: const Icon(Icons.public),
            label: l10n.navRegions,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings),
            label: l10n.navSettings,
          ),
        ],
      ),
    );
  }
}
