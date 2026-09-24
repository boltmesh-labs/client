import 'dart:async';
import 'dart:convert';

import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/secure_storage.dart';

/// [MapSecureStorage] with controllable gates/errors so tests can hold a write
/// open, fail a delete, and assert the store's ordering guarantees.
class _GatedStorage extends MapSecureStorage {
  _GatedStorage([super.seed]);

  /// When set, the Nth `write` (0-based) parks until this gate completes.
  final List<Completer<void>> writeGates = [];
  int writeCount = 0;
  int deleteCount = 0;
  Object? writeError;
  Object? deleteError;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final index = writeCount++;
    if (index < writeGates.length) await writeGates[index].future;
    final error = writeError;
    if (error != null) throw error;
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteCount++;
    final error = deleteError;
    if (error != null) throw error;
    await super.delete(key: key);
  }
}

void main() {
  test(
    'clearDevice wipes the whole identity including the device name',
    () async {
      final storage = MapSecureStorage();
      final store = DeviceStore(storage);
      await store.setDeviceId('dev-1');
      await store.setKeypair(privateKey: 'priv', publicKey: 'pub');
      await store.setDeviceName('Old Phone');
      await store.setProvisionKey('idem');
      await store.setProvisionTarget('r|s');
      await store.setLastTarget(
        regionId: 'r',
        serverId: null,
        explicitTarget: true,
      );
      await store.setLastDialJson('{}');
      await store.setAllowLocal(false);

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
      // Everything identity-shaped is gone; only the LAN preference survives.
      expect(storage.values.keys, [DeviceStore.allowLocalKey]);
      // The split-tunnel preference is not identity: it deliberately survives.
      expect(await store.allowLocal(), isFalse); // was stored as '0'
    },
  );

  test('the whole identity is one storage entry', () async {
    final storage = MapSecureStorage();
    final store = DeviceStore(storage);
    await store.setDeviceId('dev-1');
    await store.setKeypair(privateKey: 'priv', publicKey: 'pub');
    await store.setDeviceName('Phone');
    await store.setProvisionKey('idem');
    await store.setLastTarget(
      regionId: null,
      serverId: 's1',
      explicitTarget: true,
    );
    await store.setLastDialJson('{}');

    expect(storage.values.keys, [DeviceStore.identityKey]);
  });

  test(
    'the target is one value, never a torn region/server/explicit triple',
    () async {
      final storage = MapSecureStorage();
      final store = DeviceStore(storage);
      await store.setLastTarget(
        regionId: null,
        serverId: 's1',
        explicitTarget: true,
      );
      await store.setLastTarget(
        regionId: 'r1',
        serverId: null,
        explicitTarget: false,
      );

      // A single key carries the whole target: there is no second write whose
      // interleaving could persist both sides of two different selections.
      expect(storage.values.keys, [DeviceStore.identityKey]);
      final decoded =
          jsonDecode(storage.values[DeviceStore.identityKey]!) as Map;
      expect(decoded['lastTarget'], {
        'regionId': 'r1',
        'serverId': null,
        'explicit': false,
      });
    },
  );

  test('a target write queued before clearDevice cannot resurrect it', () async {
    // Reproduces the leak: selectTarget fires an unawaited write, then the
    // account wipe runs. The write is held open so, without serialization, it
    // would finish after clearDevice and recreate the old account's target.
    final storage = _GatedStorage();
    final store = DeviceStore(storage);
    final gate = Completer<void>();
    storage.writeGates.add(gate);

    final write = store.setLastTarget(
      regionId: null,
      serverId: 'old-user-server',
      explicitTarget: true,
    );
    final wipe = store.clearDevice();
    // Let the queued mutation reach the gate, then let the wipe run behind it.
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await write;
    await wipe;

    final target = await store.lastTarget();
    expect(target.serverId, isNull);
    expect(target.regionId, isNull);
    expect(storage.values, isNot(contains(DeviceStore.identityKey)));
  });

  test('concurrent target writes apply in call order', () async {
    final storage = _GatedStorage();
    final store = DeviceStore(storage);
    final firstGate = Completer<void>();
    storage.writeGates.add(firstGate); // hold the first write only

    final first = store.setLastTarget(
      regionId: null,
      serverId: 's1',
      explicitTarget: true,
    );
    final second = store.setLastTarget(
      regionId: null,
      serverId: 's2',
      explicitTarget: false,
    );
    await Future<void>.delayed(Duration.zero);
    firstGate.complete();
    await first;
    await second;

    // The later call wins; the first can never overwrite it out of order.
    final target = await store.lastTarget();
    expect(target.serverId, 's2');
    expect(target.explicitTarget, isFalse);
  });

  test('a failed clearDevice leaves the identity intact and a retry clears it', () async {
    final storage = _GatedStorage({
      DeviceStore.identityKey: jsonEncode({
        'deviceId': 'dev-1',
        'deviceName': 'Old Phone',
        'lastTarget': {'regionId': null, 'serverId': 's', 'explicit': true},
      }),
    });
    final store = DeviceStore(storage);
    storage.deleteError = StateError('keychain locked');

    await expectLater(store.clearDevice(), throwsA(isA<StateError>()));
    // One atomic delete means a failure removes nothing: no half-wiped identity
    // (device id without its keypair, etc.) can survive.
    expect(await store.deviceId(), 'dev-1');
    expect(await store.deviceName(), 'Old Phone');
    expect((await store.lastTarget()).serverId, 's');

    storage.deleteError = null;
    await store.clearDevice();
    expect(await store.deviceId(), isNull);
    expect(await store.deviceName(), isNull);
    expect((await store.lastTarget()).serverId, isNull);
    expect(storage.deleteCount, 2);
    expect(storage.values, isEmpty);
  });

  test('setLastTarget rejects a two-sided target', () {
    final store = DeviceStore(MapSecureStorage());
    expect(
      () => store.setLastTarget(
        regionId: 'r',
        serverId: 's',
        explicitTarget: true,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('setDeviceName enforces the backend length contract', () async {
    final store = DeviceStore(MapSecureStorage());
    final atLimit = 'a' * maxDeviceNameLength;
    await store.setDeviceName(atLimit);
    expect(await store.deviceName(), atLimit);

    expect(
      () => store.setDeviceName('a' * (maxDeviceNameLength + 1)),
      throwsA(isA<ArgumentError>()),
    );
    expect(await store.deviceName(), atLimit, reason: 'reject must not write');
  });

  test('setDeviceName counts code points, not UTF-16 units', () async {
    final store = DeviceStore(MapSecureStorage());
    // Each thumbs-up is one Unicode code point (the unit the backend counts)
    // but two UTF-16 code units, so a code-unit check would wrongly reject it.
    final emoji = '\u{1F44D}' * maxDeviceNameLength;
    await store.setDeviceName(emoji);
    expect(await store.deviceName(), emoji);

    expect(
      () => store.setDeviceName('$emoji\u{1F44D}'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('setDeviceName rejects an empty or whitespace-only name', () {
    final store = DeviceStore(MapSecureStorage());
    expect(() => store.setDeviceName(''), throwsA(isA<ArgumentError>()));
    expect(() => store.setDeviceName('   '), throwsA(isA<ArgumentError>()));
  });

  test('keypair is one atomic entry inside the identity document', () async {
    final storage = MapSecureStorage();
    final store = DeviceStore(storage);
    await store.setKeypair(privateKey: 'priv', publicKey: 'pub');
    expect(storage.values.keys, [DeviceStore.identityKey]);
    expect(await store.privateKey(), 'priv');
    expect(await store.publicKey(), 'pub');
  });

  test('a corrupt identity document reads as absent', () async {
    final store = DeviceStore(
      MapSecureStorage({DeviceStore.identityKey: 'not-json'}),
    );
    expect(await store.deviceId(), isNull);
    expect(await store.privateKey(), isNull);
    expect(await store.publicKey(), isNull);
    expect(await store.deviceName(), isNull);
    expect((await store.lastTarget()).serverId, isNull);
    expect(await store.lastDialJson(), isNull);
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
