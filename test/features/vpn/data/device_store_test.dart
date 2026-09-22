import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/secure_storage.dart';

void main() {
  test('clearDevice wipes identity including the device name', () async {
    final storage = MapSecureStorage({
      DeviceStore.deviceIdKey: 'dev-1',
      DeviceStore.deviceNameKey: 'Old Phone',
      DeviceStore.provisionKeyKey: 'idem',
      DeviceStore.provisionTargetKey: 'r|s',
      DeviceStore.lastRegionKey: 'r',
      DeviceStore.lastServerKey: 's',
      DeviceStore.lastExplicitKey: '1',
      DeviceStore.lastDialKey: '{}',
      DeviceStore.allowLocalKey: '0',
    });
    final store = DeviceStore(storage);
    await store.setKeypair(privateKey: 'priv', publicKey: 'pub');
    expect(await store.privateKey(), 'priv');
    expect(await store.publicKey(), 'pub');

    await store.clearDevice();

    expect(await store.deviceId(), isNull);
    expect(await store.privateKey(), isNull);
    expect(await store.publicKey(), isNull);
    // The custom name must not leak into the next account on this install.
    expect(await store.deviceName(), isNull);
    expect(await store.provisionKey(), isNull);
    expect(await store.provisionTarget(), isNull);
    final target = await store.lastTarget();
    expect(target.regionId, isNull);
    expect(target.serverId, isNull);
    expect(target.explicitTarget, isFalse);
    expect(await store.lastDialJson(), isNull);
    // The split-tunnel preference is not identity: it deliberately survives.
    expect(await store.allowLocal(), isFalse); // was stored as '0'
  });

  test('keypair is one atomic entry, never two', () async {
    final storage = MapSecureStorage();
    final store = DeviceStore(storage);
    await store.setKeypair(privateKey: 'priv', publicKey: 'pub');
    expect(storage.values.keys, [DeviceStore.keypairKey]);
    expect(await store.privateKey(), 'priv');
    expect(await store.publicKey(), 'pub');
  });

  test('a corrupt keypair entry reads as absent', () async {
    final store = DeviceStore(
      MapSecureStorage({DeviceStore.keypairKey: 'not-json'}),
    );
    expect(await store.privateKey(), isNull);
    expect(await store.publicKey(), isNull);
  });

  test('clearDevice keeps the LAN preference default when unset', () async {
    final store = DeviceStore(MapSecureStorage());
    await store.clearDevice();
    expect(await store.allowLocal(), isTrue);
  });

  test('lastTarget round-trips and clears one side at a time', () async {
    final store = DeviceStore(MapSecureStorage());

    await store.setLastTarget(
      regionId: 'r1',
      serverId: null,
      explicitTarget: true,
    );
    var target = await store.lastTarget();
    expect(target.regionId, 'r1');
    expect(target.serverId, isNull);
    expect(target.explicitTarget, isTrue);

    await store.setLastTarget(
      regionId: null,
      serverId: 's1',
      explicitTarget: false,
    );
    target = await store.lastTarget();
    expect(target.regionId, isNull);
    expect(target.serverId, 's1');
    expect(target.explicitTarget, isFalse);
  });

  test('clearProvisionKey keeps the device identity', () async {
    final store = DeviceStore(MapSecureStorage());
    await store.setDeviceId('dev-1');
    await store.setProvisionKey('idem');
    await store.setProvisionTarget('r|s');

    await store.clearProvisionKey();

    expect(await store.provisionKey(), isNull);
    expect(await store.provisionTarget(), isNull);
    expect(await store.deviceId(), 'dev-1');
  });

  test('an explicit strict LAN preference survives clearDevice', () async {
    final store = DeviceStore(MapSecureStorage());
    await store.setAllowLocal(false);
    await store.clearDevice();
    expect(await store.allowLocal(), isFalse);
  });
}
