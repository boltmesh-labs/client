import 'dart:async';

import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart'
    show ConnectivityPlatform;
import 'package:flutter_test/flutter_test.dart';

/// Fake platform behind `Connectivity` (which cannot be subclassed — it is a
/// private-constructor singleton), injected via [ConnectivityPlatform.instance].
class _FakeConnectivityPlatform extends ConnectivityPlatform {
  List<ConnectivityResult> results = const <ConnectivityResult>[];
  StreamController<List<ConnectivityResult>>? controller;
  Object? error;
  int checks = 0;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    checks++;
    final failure = error;
    if (failure != null) throw failure;
    return results;
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    final failure = error;
    if (failure != null) throw failure;
    return controller?.stream ?? const Stream.empty();
  }
}

void main() {
  late ConnectivityPlatform original;

  setUp(() => original = ConnectivityPlatform.instance);
  tearDown(() => ConnectivityPlatform.instance = original);

  ConnectivityNetworkMonitor monitorFor(_FakeConnectivityPlatform platform) {
    ConnectivityPlatform.instance = platform;
    return ConnectivityNetworkMonitor();
  }

  group('hasLink', () {
    test('is true when at least one real transport is present', () async {
      expect(
        await monitorFor(
          _FakeConnectivityPlatform()..results = [ConnectivityResult.wifi],
        ).hasLink(),
        isTrue,
      );
      expect(
        await monitorFor(
          _FakeConnectivityPlatform()
            ..results = [ConnectivityResult.none, ConnectivityResult.mobile],
        ).hasLink(),
        isTrue,
      );
    });

    test('is false for none or an empty transport list', () async {
      expect(await monitorFor(_FakeConnectivityPlatform()).hasLink(), isFalse);
      expect(
        await monitorFor(
          _FakeConnectivityPlatform()..results = [ConnectivityResult.none],
        ).hasLink(),
        isFalse,
      );
    });

    test('fails open (assumes online) when the plugin throws', () async {
      final platform = _FakeConnectivityPlatform()
        ..error = StateError('wedged');
      expect(await monitorFor(platform).hasLink(), isTrue);
    });
  });

  group('linkChanges', () {
    test('maps transports to distinct up/down transitions', () async {
      final platform = _FakeConnectivityPlatform();
      final controller = StreamController<List<ConnectivityResult>>();
      platform.controller = controller;
      final monitor = monitorFor(platform);

      final expectation = expectLater(
        monitor.linkChanges,
        emitsInOrder(<bool>[true, false, true]),
      );

      controller
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.mobile]);

      await expectation;
      await controller.close();
      platform.controller = null;
    });

    test('degrades to an empty stream when the plugin throws', () async {
      final platform = _FakeConnectivityPlatform()
        ..error = StateError('wedged');
      expect(await monitorFor(platform).linkChanges.toList(), isEmpty);
    });
  });
}
