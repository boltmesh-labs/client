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
      regionId: 'r-1',
      serverId: 's-1',
      deviceStatus: _status,
      healthNote: 'stale',
      lastStage: VpnStage.connected,
    );

    final kept = full.copyWith(message: 'x');
    expect(kept.dial, _dial);
    expect(kept.regionId, 'r-1');
    expect(kept.deviceStatus, _status);
    expect(kept.healthNote, 'stale');
    expect(kept.lastStage, VpnStage.connected);

    final cleared = full.copyWith(
      dial: null,
      regionId: null,
      serverId: null,
      deviceStatus: null,
      lastStatusAt: null,
      healthNote: null,
      lastStage: null,
    );
    expect(cleared.dial, isNull);
    expect(cleared.regionId, isNull);
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

  test('selectTarget always replaces both sides', () {
    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWithValue(
          support.FakeNetworkMonitor(true),
        ),
      ],
    );
    addTearDown(container.dispose);
    final ctl = container.read(connectionProvider.notifier);

    // Pin a server, then Quick Connect a region: the stale server must not
    // survive (wrong-target bug: keep-semantics provisioned to s-1 while
    // the UI showed r-2).
    ctl.selectTarget(regionId: null, serverId: 's-1');
    ctl.selectTarget(regionId: 'r-2', serverId: null);
    var state = container.read(connectionProvider);
    expect(state.regionId, 'r-2');
    expect(state.serverId, isNull);

    // Mirror: pin a region, then tap a server.
    ctl.selectTarget(regionId: 'r-1', serverId: null);
    ctl.selectTarget(regionId: null, serverId: 's-2');
    state = container.read(connectionProvider);
    expect(state.regionId, isNull);
    expect(state.serverId, 's-2');
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
    ctl.selectTarget(regionId: 'r-1', serverId: null);
    expect(container.read(connectionProvider).explicitTarget, isFalse);

    // Manual taps set it.
    ctl.selectTarget(regionId: 'r-1', serverId: null, explicitTarget: true);
    expect(container.read(connectionProvider).explicitTarget, isTrue);

    // Internal re-pins (null) preserve it across target changes.
    ctl.selectTarget(regionId: null, serverId: 's-2');
    var state = container.read(connectionProvider);
    expect(state.serverId, 's-2');
    expect(state.explicitTarget, isTrue);

    // Auto paths clear it explicitly.
    ctl.selectTarget(regionId: 'r-9', serverId: null, explicitTarget: false);
    state = container.read(connectionProvider);
    expect(state.regionId, 'r-9');
    expect(state.explicitTarget, isFalse);
  });
}
