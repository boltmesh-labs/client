/// UI-facing VPN providers, composed on top of the controller's own
/// dependency graph (`connection_controller.dart`).
///
/// Everything the controller needs lives with it; this file holds the
/// discovery cache the Regions tab watches and re-exports the controller, so
/// `vpn_providers.dart` stays the single import for UI and tests.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/env.dart';
import '../../../core/log.dart';
import '../data/models.dart';
import 'connection_controller.dart';

export 'connection_controller.dart';

extension _KeepAlive on Ref {
  void keepAliveFor(Duration d) {
    final link = keepAlive();
    Future.delayed(d, link.close);
  }
}

/// Cached discovery (backend allows 60s client caching).
///
/// `autoDispose` + [keepAliveFor] keep a fetched list for
/// [Env.regionsCacheTtl] after the last listener detaches, so a remount
/// reuses fresh data instead of spinning. The shell keeps the Regions tab
/// mounted (IndexedStack), so in practice the screen's listener holds the
/// provider for the session and refresh is explicit: pull-to-refresh, the
/// AppBar button, or the error branch's Retry.
final regionsProvider = FutureProvider.autoDispose<List<Region>>((ref) async {
  final api = ref.watch(vpnApiProvider);
  try {
    final regions = await api.regions();
    ref.keepAliveFor(Env.regionsCacheTtl);
    return regions;
  } catch (e) {
    AppLog.error('regions refresh failed', e);
    rethrow;
  }
});
