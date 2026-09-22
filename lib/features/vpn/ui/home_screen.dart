import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'home/backend_banner.dart';
import 'home/health_banner.dart';
import 'home/power_button.dart';
import 'home/status_header.dart';
import 'home/traffic_card.dart';

/// Connect tab: status header, hero power toggle, backend-unreachable
/// banner, traffic counters, and the degraded-tunnel banner.
///
/// The hero power button doubles as the error-phase recovery action
/// (it shows Connect and reconciles via config/connect), so no separate
/// retry button is needed.
///
/// Each section is its own widget watching only the slice it renders, so
/// background traffic ticks don't rebuild the whole tab.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: const Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusHeader(),
              SizedBox(height: 24),
              PowerButton(),
              BackendBanner(),
              TrafficCard(),
              HealthBanner(),
            ],
          ),
        ),
      ),
    );
  }
}
