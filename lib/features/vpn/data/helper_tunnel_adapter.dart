import 'dart:async';

import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../core/log.dart';
import 'helper_client.dart';
import 'tunnel_adapter.dart';
import 'tunnel_tuning.dart';

/// [TunnelAdapter] over the privileged `boltmeshd` helper.
///
/// Used on Linux and Windows in place of `WireGuardTunnelAdapter`: on Linux
/// the plugin's backend shells out to `sudo wg`/`sudo wg-quick`, and on
/// Windows it creates and starts a LocalSystem service, both of which put a
/// privileged surface inside the UI process. Every read and write goes
/// through the helper transport (a Unix socket on Linux, a named pipe on
/// Windows).
///
/// Read semantics match the rest of the app: null means "unknown" and must
/// never be treated as a stall on its own. The daemon is authoritative for
/// the stage, so [stages] stays empty and `readStage()` (polled by the health
/// tick) is the truth — outside-stop corroboration still works via
/// `_noteStage`.
class HelperTunnelAdapter implements TunnelAdapter {
  HelperTunnelAdapter({HelperClient? client})
    : _client = client ?? HelperClient();

  final HelperClient _client;
  bool _initialized = false;

  @override
  bool get isReady => _initialized;

  /// The helper has no push channel; the health tick polls [readStage].
  @override
  Stream<VpnStage> get stages => const Stream.empty();

  @override
  bool get handshakeReaderSupported => true;

  @override
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await _client.ping(timeout: TunnelTuning.healthTimeout);
    _initialized = true;
  }

  @override
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
  }) async {
    await _client.up(wgQuickConfig, timeout: TunnelTuning.helperOpTimeout);
    _initialized = true;
  }

  @override
  Future<void> stop(String reason) async {
    try {
      await _client.down(timeout: TunnelTuning.stopTimeout);
      AppLog.info('helper tunnel stopped ($reason)');
      return;
    } on TimeoutException catch (e) {
      AppLog.error('helper stop timed out ($reason), retrying', e);
    } catch (e) {
      AppLog.error('helper stop failed ($reason), retrying', e);
    }
    try {
      await _client.down(timeout: TunnelTuning.helperStopRetryTimeout);
      AppLog.info('helper tunnel stopped on retry ($reason)');
    } catch (e) {
      AppLog.error('helper stop retry failed ($reason)', e);
    }
  }

  @override
  Future<VpnStage?> readStage() async {
    try {
      return _stageOf(
        await _client.status(timeout: TunnelTuning.healthTimeout),
      );
    } catch (e) {
      AppLog.info('helper stage read failed (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> readTraffic() async {
    try {
      final status = await _client.status(timeout: TunnelTuning.healthTimeout);
      if (!status.up) return null;
      return {'rxBytes': status.rxBytes, 'txBytes': status.txBytes};
    } catch (e) {
      AppLog.info('helper traffic read failed (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<DateTime?> readHandshake() async {
    try {
      final status = await _client.status(timeout: TunnelTuning.healthTimeout);
      return status.up ? status.lastHandshake : null;
    } catch (e) {
      AppLog.info('helper handshake read failed (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<ActivePeer?> getActivePeer() async {
    try {
      final status = await _client.status(timeout: TunnelTuning.healthTimeout);
      if (!status.up || status.publicKey.isEmpty) return null;
      return ActivePeer(publicKey: status.publicKey, endpoint: status.endpoint);
    } catch (e) {
      AppLog.info('helper active peer unavailable (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<bool> killGhost() async {
    try {
      final status = await _client.down(timeout: TunnelTuning.helperOpTimeout);
      return !status.up;
    } catch (e) {
      AppLog.info('helper ghost kill failed (ignoring): $e');
      return false;
    }
  }
}

/// Maps a validated helper stage to the app's [VpnStage].
///
/// [HelperStatus.fromJson] rejects any stage outside the contract, so the
/// default is defensive only: an unexpected value must never be reported as
/// [VpnStage.connected] on the strength of `up` (that would suppress
/// tunnel-death detection), so it degrades to disconnected instead.
VpnStage _stageOf(HelperStatus status) {
  switch (status.stage) {
    case 'connected':
      return VpnStage.connected;
    case 'connecting':
      return VpnStage.connecting;
    case 'disconnected':
      return VpnStage.disconnected;
    default:
      return VpnStage.disconnected;
  }
}
