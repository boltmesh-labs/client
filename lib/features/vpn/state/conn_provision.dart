part of 'connection_controller.dart';

extension ConnectionProvision on ConnectionController {
  Future<void> _provision({
    String? regionId,
    String? serverId,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) return;
    snap = snap.copyWith(phase: ConnPhase.working, message: 'Provisioning…');
    try {
      final existing = await _device.deviceId();
      if (!sessionCurrent()) return;
      AppLog.info(
        'provision start device=${AppLog.redact(existing)} '
        'region=${regionId ?? snap.regionId ?? '<auto>'} '
        'server=${serverId ?? snap.serverId ?? '<auto>'}',
      );
      if (existing != null) {
        AppLog.info('provision skip device=${AppLog.redact(existing)} exists');
        snap = snap.copyWith(phase: ConnPhase.idle, message: 'Ready');
        return;
      }
      // An interrupted provision leaves a (keypair, idempotency key) pair in
      // the store: retry with the same pair so the idempotency key keeps
      // mapping to the same public key. The key is bound to its target —
      // a retry with a different target mints a fresh pair, otherwise the
      // same key with a different body 409s forever (body conflict).
      final target =
          'region=${regionId ?? snap.regionId ?? ''}'
          '|server=${serverId ?? snap.serverId ?? ''}';
      String? storedTarget;
      try {
        storedTarget = await _device.provisionTarget();
        if (!sessionCurrent()) return;
      } catch (_) {
        // Stores without target support (older fakes): fall back to
        // unbound retries so the same-target retry still reuses the key.
        storedTarget = target;
      }
      var idem = await _device.provisionKey();
      var pub = await _device.publicKey();
      if (!sessionCurrent()) return;
      if (idem == null ||
          pub == null ||
          await _device.privateKey() == null ||
          storedTarget != target) {
        final kp = await _keys.generate();
        if (!sessionCurrent()) return;
        pub = kp.publicKey;
        idem = const Uuid().v4();
        await _device.setKeypair(privateKey: kp.privateKey, publicKey: pub);
        if (!sessionCurrent()) return;
        await _device.setProvisionKey(idem);
        try {
          await _device.setProvisionTarget(target);
        } catch (_) {
          // Older/test stores without the target key: fall back to
          // unbound retries (conflicts surface as errors, not loops
          // within a single target).
        }
      }
      final name = await _device.deviceName() ?? 'BoltMesh Device';
      if (!sessionCurrent()) return;
      final targetRegionId = regionId ?? snap.regionId;
      final targetServerId = serverId ?? snap.serverId;
      // Pin to finals: the closure below can't see the null-promotion of
      // the mutable [pub]/[idem] locals.
      final effectivePub = pub;
      final effectiveIdem = idem;
      Future<DialParams> postProvision() => _api.provision(
        name: name,
        platform: currentPlatformLabel(),
        publicKey: effectivePub,
        serverId: targetServerId,
        regionId: targetRegionId,
        idempotencyKey: effectiveIdem,
      );
      DialParams dial;
      try {
        dial = await postProvision();
        if (!sessionCurrent()) return;
      } on DioException catch (e) {
        // The first attempt may have created the device while its response
        // was lost: replay once with the same key/body (idempotent) instead
        // of surfacing a spurious conflict. A second failure (e.g. a true
        // body conflict) surfaces normally.
        if (asVpnError(e)?.kind != ApiErrorKind.idempotencyConflict) {
          rethrow;
        }
        AppLog.info('provision idempotency conflict -> one same-key retry');
        dial = await postProvision();
        if (!sessionCurrent()) return;
      }
      if (!sessionCurrent()) return;
      await _device.setDeviceId(dial.deviceId);
      await _device.clearProvisionKey();
      if (!sessionCurrent()) return;
      AppLog.info(
        'provision ok device=${AppLog.redact(dial.deviceId)} '
        'server=${dial.serverName}',
      );
      snap = snap.copyWith(phase: ConnPhase.idle, dial: dial, message: 'Ready');
    } catch (e) {
      if (!sessionCurrent()) return;
      final vpnErr = asVpnError(e);
      AppLog.error(
        'provision failed kind=${vpnErr?.kind ?? e.runtimeType}',
        vpnErr?.message ?? e,
      );
      final rateWait = _noteRateLimit(vpnErr);
      if (vpnErr?.kind == ApiErrorKind.notFound) {
        await _device.clearDevice();
      }
      if (vpnErr?.kind == ApiErrorKind.validation) {
        // Bad request: the stored key/target pair will fail the same way,
        // so drop it and mint fresh next time.
        try {
          await _device.clearProvisionKey();
        } catch (e) {
          AppLog.error('provision clear key failed', e);
        }
      }
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: rateWait != null
            ? _rateLimitMessage(rateWait)
            : (vpnErr?.message ?? e.toString()),
        opFailed: true,
      );
      rethrow;
    }
  }
}
