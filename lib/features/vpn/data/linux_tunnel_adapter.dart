import 'dart:async';

import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../core/log.dart';
import 'helper_client.dart';
import 'tunnel_adapter.dart';
import 'tunnel_tuning.dart';

/// [TunnelAdapter] over the privileged `boltmeshd` daemon.
///
/// Used on Linux in place of `WireGuardTunnelAdapter`: the plugin's Linux
/// backend shells out to `sudo wg`/`sudo wg-quick` from the UI process, which
/// is exactly the privileged surface this adapter removes. Every read and
/// write goes through the helper socket.
///
/// Read semantics match the rest of the app: null means "unknown" and must
/// never be treated as a stall on its own. The daemon is authoritative for
/// the stage, so [stages] stays empty and `readStage()` (polled by the health
/// tick) is the truth — outside-stop corroboration still works via
/// `_noteStage`.
class LinuxTunnelAdapter implements TunnelAdapter {
  LinuxTunnelAdapter({HelperClient? client})
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
    await _client.ping().timeout(TunnelTuning.opTimeout);
    _initialized = true;
  }

  @override
  Future<void> start({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleId,
  }) async {
    await _client.up(wgQuickConfig).timeout(TunnelTuning.opTimeout);
    _initialized = true;
  }

  @override
  Future<void> stop(String reason) async {
    try {
      await _client.down().timeout(TunnelTuning.stopTimeout);
      AppLog.info('helper tunnel stopped ($reason)');
      return;
    } on TimeoutException catch (e) {
      AppLog.error('helper stop timed out ($reason), retrying', e);
    } catch (e) {
      AppLog.error('helper stop failed ($reason), retrying', e);
    }
    try {
      await _client.down().timeout(TunnelTuning.stopTimeout);
      AppLog.info('helper tunnel stopped on retry ($reason)');
    } catch (e) {
      AppLog.error('helper stop retry failed ($reason)', e);
    }
  }

  @override
  Future<VpnStage?> readStage() async {
    try {
      return _stageOf(
        await _client.status().timeout(TunnelTuning.healthTimeout),
      );
    } catch (e) {
      AppLog.info('helper stage read failed (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> readTraffic() async {
    try {
      final status = await _client.status().timeout(TunnelTuning.healthTimeout);
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
      final status = await _client.status().timeout(TunnelTuning.healthTimeout);
      return status.up ? status.lastHandshake : null;
    } catch (e) {
      AppLog.info('helper handshake read failed (unknown, ignoring): $e');
      return null;
    }
  }

  @override
  Future<ActivePeer?> getActivePeer() async {
    try {
      final status = await _client.status().timeout(TunnelTuning.healthTimeout);
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
      final status = await _client.down().timeout(TunnelTuning.opTimeout);
      return !status.up;
    } catch (e) {
      AppLog.info('helper ghost kill failed (ignoring): $e');
      return false;
    }
  }
}

VpnStage _stageOf(HelperStatus status) {
  switch (status.stage) {
    case 'connected':
      return VpnStage.connected;
    case 'connecting':
      return VpnStage.connecting;
    default:
      return status.up ? VpnStage.connected : VpnStage.disconnected;
  }
}
