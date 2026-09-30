import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/fakes.dart' as support;

const _dial = DialParams(
  deviceId: 'dev-1',
  assignedIp: '10.8.0.2',
  serverId: 's-1',
  serverName: 'one',
  endpoint: 'one.example.com',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  wgPublicKey: 'srv-pub',
);

const _status = DeviceStatus(
  deviceId: 'dev-1',
  status: 'active',
  tier: 'Pro',
  maxDevices: 5,
  activeDevices: 1,
);

void main() {
  test('omitted nullable args keep, explicit null clears', () {
    const full = ConnState(
      dial: _dial,
      serverId: 's-1',
      deviceStatus: _status,
      healthNote: 'stale',
      lastStage: VpnStage.connected,
    );

    final kept = full.copyWith(message: 'x');
    expect(kept.dial, _dial);
    expect(kept.serverId, 's-1');
    expect(kept.deviceStatus, _status);
    expect(kept.healthNote, 'stale');
    expect(kept.lastStage, VpnStage.connected);

    final cleared = full.copyWith(
      dial: null,
      serverId: null,
      deviceStatus: null,
      lastStatusAt: null,
      healthNote: null,
      lastStage: null,
    );
    expect(cleared.dial, isNull);
    expect(cleared.serverId, isNull);
    expect(cleared.deviceStatus, isNull);
    expect(cleared.healthNote, isNull);
    expect(cleared.lastStage, isNull);
    // Non-nullable fields are untouched by the sentinel change.
    expect(cleared.phase, full.phase);
    expect(cleared.pollFailures, full.pollFailures);
  });

  test('traffic counters keep by default, clear on explicit null', () {
    const withTraffic = ConnState(rxBytes: 100, txBytes: 50);

    final kept = withTraffic.copyWith(message: 'x');
    expect(kept.rxBytes, 100);
    expect(kept.txBytes, 50);

    final cleared = withTraffic.copyWith(rxBytes: null, txBytes: null);
    expect(cleared.rxBytes, isNull);
    expect(cleared.txBytes, isNull);
  });

  test('selectTarget replaces the pinned server and null clears it', () {
    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWithValue(
          support.FakeNetworkMonitor(true),
        ),
      ],
    );
    addTearDown(container.dispose);
    final ctl = container.read(connectionProvider.notifier);

    ctl.selectTarget(serverId: 's-1');
    ctl.selectTarget(serverId: 's-2');
    var state = container.read(connectionProvider);
    expect(state.serverId, 's-2');

    ctl.selectTarget(serverId: null);
    state = container.read(connectionProvider);
    expect(state.serverId, isNull);
  });

  test('selectTarget explicit flag defaults false, preserves, overrides', () {
    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWithValue(
          support.FakeNetworkMonitor(true),
        ),
      ],
    );
    addTearDown(container.dispose);
    final ctl = container.read(connectionProvider.notifier);

    // Auto pins leave the flag false.
    ctl.selectTarget(serverId: null);
    expect(container.read(connectionProvider).explicitTarget, isFalse);

    // Manual taps set it.
    ctl.selectTarget(serverId: 's-1', explicitTarget: true);
    expect(container.read(connectionProvider).explicitTarget, isTrue);

    // Internal re-pins (null) preserve it across target changes.
    ctl.selectTarget(serverId: 's-2');
    var state = container.read(connectionProvider);
    expect(state.serverId, 's-2');
    expect(state.explicitTarget, isTrue);

    // Auto paths clear it explicitly.
    ctl.selectTarget(serverId: 's-9', explicitTarget: false);
    state = container.read(connectionProvider);
    expect(state.serverId, 's-9');
    expect(state.explicitTarget, isFalse);
  });
}
