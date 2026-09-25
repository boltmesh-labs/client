// Shared test doubles for the VPN suite.
//
// Every entry mirrors a production seam (`WireGuardFlutterInterface`,
// `DeviceStore`, `KeyManager`, the diagnostic probes) that the VPN tests
// would otherwise re-declare in each file. The individual test files alias
// the stateless doubles with `typedef` and keep only the subclasses that add
// a default, so call sites stay unchanged. `vpn_harness.dart` layers the
// shared Dio/JSON/exception fixtures on top of these.
//
// Not a `*_test.dart` file: `flutter test` only collects those. Keep this
// dependency-light (no app state-layer imports) so it stays a leaf.
//
// `test/widget_test.dart` and `lib/previews.dart` intentionally keep their own
// tiny const store doubles: those must stay `const`-constructible and
// previews cannot import from `test/`.

import 'dart:async';

import 'package:boltmesh/core/clock.dart';
import 'package:boltmesh/features/vpn/data/control_probe.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/gateway_probe.dart';
import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/data/key_manager.dart';
import 'package:boltmesh/features/vpn/data/network_monitor.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

/// Deterministic [Clock] for tests that age the controller's time windows.
///
/// Starts at a fixed instant (never the wall clock) so a suite can connect at
/// its origin and then [advance] to age handshake/grace/quiet windows without
/// touching private anchors.
class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026);

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) => _now = _now.add(duration);
}

/// Configurable native-tunnel double.
///
/// Records `tunnel:start` / `tunnel:stop` into [events] and every wgQuick
/// config into [configs] (see [lastConfig]), and can be switched into the
/// wedged-driver modes the health pipeline must survive — a timing-out traffic
/// read ([wedgeTraffic]) and an unreadable stage ([failStage]).
class FakeTunnel implements WireGuardFlutterInterface {
  FakeTunnel({
    List<String>? events,
    this.stageValue = VpnStage.connected,
    Map<String, dynamic>? traffic,
  }) : events = events ?? <String>[],
       traffic = traffic ?? const {};

  final List<String> events;

  /// Current stage: what `stage()`/`isConnected()` answer, and what [emit]
  /// pushes to [vpnStageSnapshot].
  VpnStage stageValue;

  /// Payload returned by [trafficStats].
  Map<String, dynamic> traffic;

  /// Number of [trafficStats] calls (foreground/background gating tests).
  int trafficReads = 0;

  /// wgQuick configs passed to [startVpn], in order.
  final List<String> configs = [];

  /// Last config handed to [startVpn] (null before the first start).
  String? get lastConfig => configs.isEmpty ? null : configs.last;

  /// Test hook run inside [startVpn] (e.g. to observe an unexpected restart
  /// while a ghost-kill is in flight).
  Future<void> Function()? onStart;

  /// When true, [trafficStats] throws like a stuck Wintun driver: the
  /// production adapter times out and reports null (unknown, never a stall on
  /// its own).
  bool wedgeTraffic = false;

  /// When true, `stage()` throws (wedged driver IPC) so the adapter read
  /// yields null and the reconcile null-path is exercised.
  bool failStage = false;

  final _stages = StreamController<VpnStage>.broadcast();

  /// Pushes [s] to [vpnStageSnapshot] and remembers it for `stage()`.
  void emit(VpnStage s) {
    stageValue = s;
    _stages.add(s);
  }

  /// Pushes an error to [vpnStageSnapshot], like a broken platform channel.
  /// The controller must log it without letting it become an unhandled
  /// async error or dropping the subscription.
  void emitError(Object error) => _stages.addError(error);

  /// Closes [vpnStageSnapshot]. Call from `addTearDown` so container
  /// disposal unwinds with no in-flight stage events.
  Future<void> close() => _stages.close();

  @override
  Stream<VpnStage> get vpnStageSnapshot => _stages.stream;

  @override
  Stream<Map<String, dynamic>> get trafficSnapshot => const Stream.empty();

  @override
  Future<void> initialize({
    required String interfaceName,
    String? vpnName,
    String? iosAppGroup,
    String? extensionBundleId,
  }) async {
    initialized = true;
    this.interfaceName = interfaceName;
    this.vpnName = vpnName;
    this.iosAppGroup = iosAppGroup;
    this.extensionBundleId = extensionBundleId;
  }

  /// `initialize` was called (the adapter only reports ready afterwards).
  bool initialized = false;
  String? interfaceName;
  String? vpnName;

  /// The App Group handed to the plugin. Null means the call site omitted it,
  /// which on Apple makes the plugin fall back to a group that is in no
  /// provisioning profile.
  String? iosAppGroup;
  String? extensionBundleId;

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
    List<String>? excludedApps,
    List<String>? includedApps,
  }) async {
    events.add('tunnel:start');
    configs.add(wgQuickConfig);
    final hook = onStart;
    if (hook != null) await hook();
  }

  @override
  Future<void> stopVpn() async => events.add('tunnel:stop');

  @override
  Future<Map<String, dynamic>> trafficStats() async {
    trafficReads++;
    if (wedgeTraffic) {
      throw TimeoutException('wedged', const Duration(seconds: 3));
    }
    return traffic;
  }

  @override
  Future<void> requestMacSystemExtension(String bundleId) async {}

  @override
  Future<bool> isConnected() async => stageValue == VpnStage.connected;

  @override
  Future<void> refreshStage() async {}

  @override
  Future<VpnStage> stage() async {
    if (failStage) throw StateError('stage unreadable');
    return stageValue;
  }

  @override
  Future<bool> checkVpnPermission() async => true;
}

/// In-memory [DeviceStore] covering every key the controller touches.
///
/// Replaces `SecureStorage` with a map, so a test can drive a full
/// provision → connect → switch → disconnect cycle with no platform channel.
class FakeDeviceStore extends DeviceStore {
  FakeDeviceStore([Map<String, String?>? seed])
    : _m = {...?seed},
      super(const FlutterSecureStorage());

  final Map<String, String?> _m;

  /// Test hook run inside [deviceId]: a real async gap inside
  /// `pollStatusOnce`, between its entry checks and the API call.
  Future<void> Function()? deviceIdHook;

  @override
  Future<String?> deviceId() async {
    final hook = deviceIdHook;
    if (hook != null) await hook();
    return _m['dev'];
  }

  @override
  Future<void> setDeviceId(String v) async => _m['dev'] = v;

  /// Test hook run inside [clearDevice]; lets a test pause the local wipe and
  /// assert the op mutex is still held (release must be atomic).
  Future<void> Function()? clearDeviceHook;

  @override
  Future<void> clearDevice() async {
    final hook = clearDeviceHook;
    if (hook != null) await hook();
    _m
      ..remove('dev')
      ..remove('priv')
      ..remove('pub')
      ..remove('name')
      ..remove('idem')
      ..remove('idem_target')
      ..remove('last_region')
      ..remove('last_server')
      ..remove('last_explicit')
      ..remove('last_dial');
  }

  /// Test hook run inside [privateKey]: lets a test make the secure-storage
  /// read throw (locked keychain) and assert the op mutex is still released.
  Future<void> Function()? privateKeyHook;

  @override
  Future<String?> privateKey() async {
    final hook = privateKeyHook;
    if (hook != null) await hook();
    return _m['priv'];
  }

  @override
  Future<String?> publicKey() async => _m['pub'];

  /// Test hook run before a keypair write; lets recovery tests model a
  /// secure-storage failure without replacing the whole store.
  Future<void> Function(String privateKey, String publicKey)? setKeypairHook;

  @override
  Future<void> setKeypair({
    required String privateKey,
    required String publicKey,
  }) async {
    final hook = setKeypairHook;
    if (hook != null) await hook(privateKey, publicKey);
    _m
      ..['priv'] = privateKey
      ..['pub'] = publicKey;
  }

  @override
  Future<String?> deviceName() async => _m['name'];

  @override
  Future<void> setDeviceName(String v) async => _m['name'] = v;

  @override
  Future<String?> provisionKey() async => _m['idem'];

  @override
  Future<void> setProvisionKey(String v) async => _m['idem'] = v;

  @override
  Future<void> clearProvisionKey() async => _m
    ..remove('idem')
    ..remove('idem_target');

  @override
  Future<String?> provisionTarget() async => _m['idem_target'];

  @override
  Future<void> setProvisionTarget(String v) async => _m['idem_target'] = v;

  @override
  Future<({String? regionId, String? serverId, bool explicitTarget})>
  lastTarget() async => (
    regionId: _m['last_region'],
    serverId: _m['last_server'],
    explicitTarget: _m['last_explicit'] == '1',
  );

  @override
  Future<void> setLastTarget({
    required String? regionId,
    required String? serverId,
    required bool explicitTarget,
  }) async {
    _m['last_region'] = regionId;
    _m['last_server'] = serverId;
    _m['last_explicit'] = explicitTarget ? '1' : '0';
  }

  @override
  Future<String?> lastDialJson() async => _m['last_dial'];

  @override
  Future<void> setLastDialJson(String v) async => _m['last_dial'] = v;

  @override
  Future<void> clearLastDial() async => _m..remove('last_dial');

  @override
  Future<bool> allowLocal() async => _m['lan'] != '0';

  @override
  Future<void> setAllowLocal(bool v) async => _m['lan'] = v ? '1' : '0';
}

/// Deterministic [KeyManager].
///
/// A queued list pops one keypair per [generate] call (holding the queue
/// empty throws, making an unexpected extra key generation obvious);
/// without a queue every call returns [fallback].
class FakeKeys extends KeyManager {
  FakeKeys([List<Keypair>? queue, this.fallback = fallbackKeypair])
    : _queue = queue;

  /// Returned when no queue was supplied: a fixed private key plus a
  /// X25519-shaped public key.
  static const fallbackKeypair = Keypair(
    'PRIV',
    'UFJJVl9QVUJMSUNfS0VZMTIzNDU2Nzg5MDEyMw==',
  );

  final List<Keypair>? _queue;
  final Keypair fallback;

  @override
  Future<Keypair> generate() async =>
      _queue == null ? fallback : _queue.removeAt(0);
}

/// [NetworkMonitor] with a mutable link state.
///
/// [emit] pushes a link transition to [linkChanges] so tests can drive the
/// controller's connectivity watcher; call [close] from `addTearDown` when a
/// test subscribes.
class FakeNetworkMonitor implements NetworkMonitor {
  FakeNetworkMonitor(this.link);

  bool link;

  final _links = StreamController<bool>.broadcast();

  @override
  Future<bool> hasLink() async => link;

  @override
  Stream<bool> get linkChanges => _links.stream;

  /// Sets [link] and pushes it to [linkChanges].
  void emit(bool value) {
    link = value;
    _links.add(value);
  }

  Future<void> close() => _links.close();
}

/// [GatewayProbe] answering a fixed in-tunnel echo result (null = unknown).
class FakeGatewayProbe implements GatewayProbe {
  FakeGatewayProbe(this.alive);

  bool? alive;

  /// Number of [echoDns] calls, for asserting the health tick's probe gate.
  int calls = 0;

  @override
  Future<bool?> echoDns(
    String ip, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    calls++;
    return alive;
  }
}

/// [ControlPlaneProbe] answering a fixed reachability result (null = unknown).
class FakeControlProbe extends ControlPlaneProbe {
  FakeControlProbe(this.reachable);

  bool? reachable;

  @override
  Future<bool?> check({Duration timeout = const Duration(seconds: 5)}) async =>
      reachable;
}

// --- boltmeshd helper transport doubles ------------------------------------
//
// The app talks to the privileged helper over a newline-delimited JSON
// transport (see `data/helper_socket.dart`). These doubles script that
// transport so the recovery paths (daemon dies, daemon restarts, stale
// config) are exercised without a real socket.

/// Canonical helper status payload (see `HelperStatus.fromJson`).
Map<String, dynamic> helperStatusJson({
  String interfaceName = 'boltmesh0',
  bool up = true,
  String stage = 'connected',
  int rxBytes = 0,
  int txBytes = 0,
  int lastHandshake = 0,
  String endpoint = '',
  String publicKey = '',
}) => {
  'interface': interfaceName,
  'up': up,
  'stage': stage,
  'rxBytes': rxBytes,
  'txBytes': txBytes,
  'lastHandshake': lastHandshake,
  'endpoint': endpoint,
  'publicKey': publicKey,
};

/// Successful helper response envelope wrapping [status]. The request `id` is
/// filled in by the socket double, mirroring the daemon's correlation echo.
Map<String, dynamic> helperOk(
  Map<String, dynamic> status, {
  List<String>? caps,
}) => {'v': helperProtocolVersion, 'ok': true, 'caps': ?caps, 'status': status};

/// Scripted [HelperSocket] for adapter-level tests.
///
/// Each [exchange] pops one step: a [Map] is returned as the response (its
/// `id` forced to the request id), an [Exception] is thrown. An exhausted
/// script throws [StateError] so an unexpectedly extra read fails loudly
/// instead of silently returning a stale response.
class ScriptedHelperSocket implements HelperSocket {
  ScriptedHelperSocket(this._steps);

  final List<Object> _steps;

  /// Every request sent, in order.
  final List<Map<String, dynamic>> requests = [];

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) async {
    requests.add(request);
    if (_steps.isEmpty) {
      throw StateError('no scripted response for ${request['op']}');
    }
    final step = _steps.removeAt(0);
    if (step is Exception) throw step;
    final response = Map<String, dynamic>.from(step as Map<String, dynamic>);
    response['id'] = request['id'];
    return response;
  }
}

/// Stateful [HelperSocket] for recovery tests: answers every op from [status]
/// until [fail] is set, when every exchange throws as if the daemon/socket is
/// gone. Clear [fail] to simulate the daemon coming back; swap [status] to
/// change what it reports.
class FakeHelperSocket implements HelperSocket {
  FakeHelperSocket({Map<String, dynamic>? status})
    : status = status ?? helperStatusJson();

  /// Status the daemon reports while reachable.
  Map<String, dynamic> status;

  /// True while the daemon is unreachable: every exchange throws.
  bool fail = false;

  /// Ops that throw even while [fail] is false. Models a daemon that answers
  /// the negotiation `ping` (init succeeds) but has gone away for the reads
  /// (`status`), which is what a mid-session restart looks like.
  Set<String> failingOps = {};

  /// Every request sent, in order.
  final List<Map<String, dynamic>> requests = [];

  /// Ops sent, in order (convenience view over [requests]).
  List<String> get ops => [for (final r in requests) r['op'] as String];

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) async {
    requests.add(request);
    final op = request['op'];
    if (fail || (op is String && failingOps.contains(op))) {
      throw HelperTransportException('helper unreachable ($op)');
    }
    return {
      'v': helperProtocolVersion,
      'id': request['id'],
      'ok': true,
      'status': status,
    };
  }
}
