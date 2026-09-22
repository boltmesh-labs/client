import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';

/// Layer 2: OS-native physical-link state.
///
/// Wraps `connectivity_plus` (`ConnectivityManager` / `NWPathMonitor` /
/// `NetworkInformation` under the hood) so the controller never fires
/// packets to learn the link is down. Fail-open: a broken plugin must
/// never pause healing forever, so errors report online (unknown).
abstract class NetworkMonitor {
  /// True when at least one non-`none` transport is reported.
  Future<bool> hasLink();

  /// Link up/down transitions as the OS reports them (true = at least one
  /// transport). Lets the controller react the moment connectivity returns
  /// instead of waiting for the next health tick. Broadcast; consumers
  /// subscribe once and must tolerate a stream that never emits or errors
  /// (fail-open, same as [hasLink]).
  Stream<bool> get linkChanges;
}

/// Production monitor over `connectivity_plus`.
class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> hasLink() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _hasTransport(results);
    } catch (e) {
      AppLog.error('network link read failed (assuming online)', e);
      return true;
    }
  }

  @override
  Stream<bool> get linkChanges {
    try {
      // `onConnectivityChanged` already de-duplicates transports; the
      // `.distinct()` collapses the multi-transport list to a single
      // up/down boolean so consumers only see real link transitions.
      return _connectivity.onConnectivityChanged.map(_hasTransport).distinct();
    } catch (e) {
      AppLog.error('network link subscription unavailable (ignoring)', e);
      return const Stream.empty();
    }
  }
}

bool _hasTransport(List<ConnectivityResult> results) =>
    results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);

final networkMonitorProvider = Provider<NetworkMonitor>(
  (_) => ConnectivityNetworkMonitor(),
);
