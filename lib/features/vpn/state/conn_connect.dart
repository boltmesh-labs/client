part of 'connection_controller.dart';

extension ConnectionConnect on ConnectionController {
  /// Lock-free connect body: caller must hold [_mutex] (see [connect] and
  /// the no-device handover in [switchServer], which stays under the switch
  /// slot instead of releasing and re-acquiring).
  ///
  /// A non-null [oneShotRegionId]/[oneShotServerId] dials that target for
  /// this call only (Auto re-pick): the pinned target in [snap] is left
  /// untouched, so an unpinned Auto stays unpinned.
  Future<void> _connectBody({
    String? oneShotRegionId,
    String? oneShotServerId,
    DialParams? knownDial,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) return;
    var id = await _device.deviceId();
    if (!sessionCurrent()) return;
    AppLog.info('connect start gen=$_tunnelEpoch device=${AppLog.redact(id)}');
    if (id == null) {
      // Freshly provisioned devices come back bound; dial straight away
      // instead of re-reading `config`. [_provision] is lock-free and
      // runs under this op's mutex slot.
      await _provision(
        regionId: oneShotRegionId,
        serverId: oneShotServerId,
        sessionEpoch: expectedSession,
      );
      if (!sessionCurrent()) return;
      final provisioned = snap.dial;
      id = await _device.deviceId();
      if (!sessionCurrent()) return;
      if (id == null || provisioned == null) {
        throw StateError('Provisioning did not return a device.');
      }
      snap = snap.copyWith(phase: ConnPhase.working, message: 'Connecting…');
      await _startWith(provisioned, sessionEpoch: expectedSession);
      return;
    }
    snap = snap.copyWith(phase: ConnPhase.working, message: 'Connecting…');
    if (knownDial != null) {
      // Caller already probed server truth (Auto Quick Connect): start the
      // live peer directly instead of re-reading `config`.
      await _startWith(knownDial, sessionEpoch: expectedSession);
      return;
    }
    if (oneShotRegionId != null || oneShotServerId != null) {
      // Auto re-pick: bind a fresh peer on the picked target instead of
      // rebuilding the still-bound old peer via `config` (which would stay
      // on the previous server and defeat the re-pick).
      final dial = await _bindFreshPeer(
        id,
        regionId: oneShotRegionId,
        serverId: oneShotServerId,
        sessionEpoch: expectedSession,
      );
      if (!sessionCurrent()) return;
      await _startWith(dial, sessionEpoch: expectedSession);
      return;
    }
    try {
      AppLog.info('connect config device=${AppLog.redact(id)}');
      final reconciled = await _configReconciled(
        id,
        sessionEpoch: expectedSession,
      );
      if (!sessionCurrent()) return;
      await _startWith(reconciled.dial, sessionEpoch: expectedSession);
      return;
    } on DioException catch (e) {
      // Only peerless (config after disconnect/GC) falls through to a
      // fresh connect. A true 404 (revoked/foreign device) and every other
      // failure (401/503/offline) surface instead of wasting a key
      // rotation on a handshake that would fail the same way.
      final kind = asVpnError(e)?.kind;
      if (kind != ApiErrorKind.noActivePeer) rethrow;
      AppLog.info(
        'connect config peerless device=${AppLog.redact(id)} -> bind fresh peer',
      );
    }
    // Ephemeral until the server binds it: persisting first would clobber
    // the working key when the POST times out (e.g. API routed into a
    // live full-tunnel) and leave the store unrecoverable.
    final dial = await _bindFreshPeer(
      id,
      regionId: oneShotRegionId,
      serverId: oneShotServerId,
      sessionEpoch: expectedSession,
    );
    if (!sessionCurrent()) return;
    await _startWith(dial, sessionEpoch: expectedSession);
  }

  /// Binds a fresh client peer for [deviceId] and returns the dial params.
  /// Lock-free: caller must hold [_mutex]. The fresh keypair stays
  /// ephemeral until the POST succeeds and is only then persisted, so a
  /// timeout can't clobber the working identity. Explicit [regionId]/
  /// [serverId] dial that target for this call only; nulls fall back to the
  /// pinned target in [snap] (both null = backend global auto-pick).
  ///
  /// [cancelToken] aborts the in-flight POST when the caller's probe times
  /// out; a cancelled (or already-cancelled) bind never persists its key, so
  /// a late success can't leave the store on a key the fallback replaced.
  Future<DialParams> _bindFreshPeer(
    String deviceId, {
    String? regionId,
    String? serverId,
    CancelToken? cancelToken,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) {
      throw StateError('Session changed before peer bind.');
    }
    final kp = await _keys.generate();
    if (!sessionCurrent()) {
      throw StateError('Session changed before peer bind.');
    }
    AppLog.info(
      'connect bind device=${AppLog.redact(deviceId)} '
      'pubkey=${AppLog.redact(kp.publicKey)}',
    );
    final dial = await _api.connect(
      deviceId: deviceId,
      publicKey: kp.publicKey,
      serverId: serverId ?? snap.serverId,
      regionId: regionId ?? snap.regionId,
      cancelToken: cancelToken,
    );
    if (!sessionCurrent()) {
      throw StateError('Session changed after peer bind.');
    }
    if (cancelToken != null && cancelToken.isCancelled) {
      // The caller already moved on: persisting now would bind this key
      // after the fallback's key, mismatching store and server.
      throw DioException(
        requestOptions: RequestOptions(path: '/vpn-devices/$deviceId/connect'),
        type: DioExceptionType.cancel,
      );
    }
    await _device.setKeypair(
      privateKey: kp.privateKey,
      publicKey: kp.publicKey,
    );
    if (!sessionCurrent()) {
      throw StateError('Session changed after peer persistence.');
    }
    return dial;
  }

  /// Connect: rebuild from `config` when bound, else bind a fresh peer.
  /// [oneShotRegionId]/[oneShotServerId] dial that target for this call
  /// only without touching the pinned target (Auto re-pick).
  Future<void> _connectOp({
    String? oneShotRegionId,
    String? oneShotServerId,
    DialParams? knownDial,
    int? expectedTeardown,
  }) async {
    final release = await _mutex.acquire('connect');
    final sessionEpoch = _sessionEpoch;
    try {
      // A lock-free caller (Quick Connect) captured [_teardownEpoch] before
      // its discovery/probe await: a Disconnect that landed meanwhile must
      // win even though this op only acquired the mutex after it. Checked
      // first so a superseded op never writes a stale stage/message.
      if (expectedTeardown != null && expectedTeardown != _teardownEpoch) {
        return;
      }
      // A throttled client must not keep spending the shared per-IP limiter
      // budget: surface the countdown and skip the network entirely.
      if (_blockedByRateLimit('connect')) return;
      if (sessionEpoch != _sessionEpoch) return;
      // Only an actual failure below sets the feedback flag again.
      snap = snap.copyWith(opFailed: false);
      await _connectBody(
        oneShotRegionId: oneShotRegionId,
        oneShotServerId: oneShotServerId,
        knownDial: knownDial,
        sessionEpoch: sessionEpoch,
      );
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error(
        'connect failed kind=${vpnErr?.kind ?? e.runtimeType}',
        vpnErr?.message ?? e,
      );
      final rateWait = _noteRateLimit(vpnErr);
      if (vpnErr?.kind == ApiErrorKind.alreadyConnected) {
        AppLog.info('connect already-connected -> reload config');
        final id = await _device.deviceId();
        if (sessionEpoch != _sessionEpoch) return;
        if (id != null) {
          try {
            final reconciled = await _configReconciled(
              id,
              sessionEpoch: sessionEpoch,
            );
            if (sessionEpoch != _sessionEpoch) return;
            final dial = reconciled.dial;
            await _startWith(dial, sessionEpoch: sessionEpoch);
            if (sessionEpoch != _sessionEpoch) return;
            await _pinCanonicalTarget(
              dial,
              regionRequest: snap.regionId != null,
            );
            if (sessionEpoch != _sessionEpoch) return;
            return;
          } catch (e2) {
            if (sessionEpoch != _sessionEpoch) return;
            final inner = asVpnError(e2);
            AppLog.error(
              'connect reload failed kind=${inner?.kind ?? e2.runtimeType}',
              inner?.message ?? e2,
            );
            final reloadWait = _noteRateLimit(inner);
            snap = snap.copyWith(
              phase: ConnPhase.error,
              message: reloadWait != null
                  ? _rateLimitMessage(reloadWait)
                  : (inner?.message ?? e2.toString()),
              opFailed: true,
            );
            return;
          }
        }
      }
      if (vpnErr?.kind == ApiErrorKind.keyInUse) {
        // Retry once with another fresh key, keeping the selected target
        // (or the one-shot Auto pick).
        AppLog.info('connect key-in-use -> retry once with fresh key');
        final retryId = await _device.deviceId();
        if (sessionEpoch != _sessionEpoch) return;
        if (retryId != null) {
          try {
            final kp = await _keys.generate();
            if (sessionEpoch != _sessionEpoch) return;
            final dial = await _api.connect(
              deviceId: retryId,
              publicKey: kp.publicKey,
              serverId: oneShotServerId ?? snap.serverId,
              regionId: oneShotRegionId ?? snap.regionId,
            );
            if (sessionEpoch != _sessionEpoch) return;
            await _device.setKeypair(
              privateKey: kp.privateKey,
              publicKey: kp.publicKey,
            );
            if (sessionEpoch != _sessionEpoch) return;
            await _startWith(dial, sessionEpoch: sessionEpoch);
            return;
          } catch (e2) {
            if (sessionEpoch != _sessionEpoch) return;
            final inner = asVpnError(e2);
            AppLog.error(
              'connect retry failed kind=${inner?.kind ?? e2.runtimeType}',
              inner?.message ?? e2,
            );
            final retryWait = _noteRateLimit(inner);
            snap = snap.copyWith(
              phase: ConnPhase.error,
              message: retryWait != null
                  ? _rateLimitMessage(retryWait)
                  : (inner?.message ?? e2.toString()),
              opFailed: true,
            );
            return;
          }
        }
      }
      if (sessionEpoch != _sessionEpoch) return;
      if (vpnErr?.kind == ApiErrorKind.notFound) {
        await _device.clearDevice();
      }
      if (sessionEpoch != _sessionEpoch) return;
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: rateWait != null
            ? _rateLimitMessage(rateWait)
            : (vpnErr?.message ?? e.toString()),
        opFailed: true,
      );
    } finally {
      release();
    }
  }

  /// Server truth for the Auto path: the device's live dial, or null when
  /// it holds no active peer (`DEVICE_NO_ACTIVE_PEER`). The dial is
  /// reconciled with the local keypair first (see [_configReconciled]), so a
  /// divergent identity is repaired before the peer is reused. Every other
  /// failure propagates to the caller.
  Future<DialParams?> _probeActiveDial(String id) async {
    try {
      final reconciled = await _configReconciled(id);
      return reconciled.dial;
    } on DioException catch (e) {
      if (asVpnError(e)?.kind == ApiErrorKind.noActivePeer) return null;
      rethrow;
    }
  }

  /// Auto Quick Connect onto [best] without pinning, without ever issuing a
  /// doomed `POST /connect`.
  ///
  /// The backend binds a fresh peer on `connect` only for a *peerless*
  /// device and 409s otherwise, but a device can already hold a server-side
  /// peer — the norm right after provision, or after a session that ended
  /// without a graceful disconnect. Ask server truth first ([_probeActiveDial]):
  ///  - live peer already inside [best] → start it as-is (no mutation);
  ///  - live peer elsewhere → one-shot `switch` onto [best];
  ///  - peerless → `connect` a fresh peer on [best].
  /// Auto stays unpinned throughout (no [selectTarget]).
  ///
  /// [expectedTeardown] is the caller's [_teardownEpoch] captured before its
  /// own discovery await: the device read and server probe below are
  /// lock-free, so a Disconnect that lands while they are in flight must
  /// abort instead of binding a fresh tunnel behind it.
  Future<void> _autoConnectRegion(Region best, {int? expectedTeardown}) async {
    final sessionEpoch = _sessionEpoch;
    final teardownEpoch = expectedTeardown ?? _teardownEpoch;
    bool superseded() =>
        sessionEpoch != _sessionEpoch || teardownEpoch != _teardownEpoch;
    final id = await _device.deviceId();
    if (superseded()) return;
    if (id == null) {
      await _connectOp(
        oneShotRegionId: best.id,
        expectedTeardown: teardownEpoch,
      );
      return;
    }
    DialParams? live;
    try {
      live = await _probeActiveDial(id);
    } catch (e) {
      if (superseded()) return;
      final vpnErr = asVpnError(e);
      AppLog.error('quick connect probe failed', vpnErr?.message ?? e);
      final wait = _noteRateLimit(vpnErr);
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: wait != null
            ? _rateLimitMessage(wait)
            : (vpnErr?.message ?? e.toString()),
        opFailed: true,
      );
      return;
    }
    // Another op may have taken over while the probe was in flight.
    if (superseded() || snap.phase == ConnPhase.working) {
      return;
    }
    if (live == null) {
      await _connectOp(
        oneShotRegionId: best.id,
        expectedTeardown: teardownEpoch,
      );
      return;
    }
    // Promote for the closure below (`live` is a nullable local).
    final peer = live;
    if (best.servers.any((s) => s.id == peer.serverId)) {
      await _connectOp(knownDial: peer, expectedTeardown: teardownEpoch);
      return;
    }
    await _switchServerOp(
      regionId: best.id,
      serverId: null,
      explicitTarget: false,
      pinTarget: false,
      expectedTeardown: teardownEpoch,
    );
  }

  /// Quick Connect shared by the Home power button and the Regions
  /// Quick-Connect tile.
  ///
  /// Sticky when a target is pinned: it redials as-is via [connect] (or
  /// [switchServer] when connected). When nothing is pinned (Auto, e.g.
  /// after [selectAuto]) the lowest-load region with capacity
  /// ([autoPickRegion]) is dialed one-shot via [_autoConnectRegion]: the
  /// state stays unpinned, so every Auto connect re-picks fresh and the
  /// next disconnect → Connect moves again instead of sticking to the old
  /// server. While connected, an Auto call no-ops when the live server is
  /// already inside the best region, else it switches one-shot without
  /// pinning. Delegates without holding the mutex: connected →
  /// [switchServer] (keeps the same-target no-op), otherwise
  /// [_autoConnectRegion] (which probes then reuses/switches/connects).
  /// Never pre-pins before a switch: that would trip the same-target skip
  /// check. A stale pin surfaces the backend error with the pin kept (no
  /// silent auto-pick fallback). The whole discovery/probe sequence is
  /// lock-free by design, so it snapshots [_teardownEpoch] up front and
  /// aborts the moment a Disconnect (or reset/revocation) has landed: the
  /// later teardown must win even though the connect started first.
  Future<void> _quickConnectOp() async {
    final sessionEpoch = _sessionEpoch;
    final teardownEpoch = _teardownEpoch;
    bool superseded() =>
        sessionEpoch != _sessionEpoch || teardownEpoch != _teardownEpoch;
    if (snap.phase == ConnPhase.working) return;
    // A throttled client must not run discovery or bind a peer either:
    // surface the countdown and skip the network entirely.
    if (_blockedByRateLimit('quick connect')) return;
    // Same as the switch op: a stale failure must not leak into this one's
    // feedback.
    snap = snap.copyWith(opFailed: false);
    // Sticky reconnect: the last selected server/region redials as-is, so
    // disconnect → Connect stays on the same target.
    if (snap.serverId != null || snap.regionId != null) {
      if (snap.phase == ConnPhase.connected) {
        await _switchServerOp(
          regionId: snap.regionId,
          serverId: snap.serverId,
          expectedTeardown: teardownEpoch,
        );
        return;
      }
      await _connectOp(expectedTeardown: teardownEpoch);
      return;
    }
    // Restart survival: the in-memory pin is gone but the persisted one
    // redials the same target (covers a GC'd peer that can't `config`).
    try {
      final saved = await _device.lastTarget();
      // Another op may have taken over while reading the store.
      if (superseded() || snap.phase == ConnPhase.working) {
        return;
      }
      if (saved.serverId != null || saved.regionId != null) {
        if (snap.phase == ConnPhase.connected) {
          await _switchServerOp(
            regionId: saved.regionId,
            serverId: saved.serverId,
            expectedTeardown: teardownEpoch,
          );
          return;
        }
        selectTarget(
          regionId: saved.regionId,
          serverId: saved.serverId,
          explicitTarget: saved.explicitTarget,
        );
        await _connectOp(expectedTeardown: teardownEpoch);
        return;
      }
    } catch (e) {
      if (superseded()) return;
      AppLog.error('quick connect saved target read failed', e);
    }
    final List<Region> regions;
    try {
      regions = await _api.regions();
    } catch (e) {
      if (superseded()) return;
      final vpnErr = asVpnError(e);
      AppLog.error('quick connect discovery failed', vpnErr?.message ?? e);
      final wait = _noteRateLimit(vpnErr);
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: wait != null
            ? _rateLimitMessage(wait)
            : (vpnErr?.message ?? e.toString()),
        opFailed: true,
      );
      return;
    }
    if (superseded()) return;
    final best = autoPickRegion(regions);
    if (best == null) {
      AppLog.info('quick connect: no capacity');
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: 'No servers available right now.',
      );
      return;
    }
    // Discovery awaited above: another op may have taken over meanwhile.
    if (superseded() || snap.phase == ConnPhase.working) {
      return;
    }
    // Auto stays unpinned: one-shot the picked region without pinning, so
    // the next connect re-picks fresh.
    if (snap.phase == ConnPhase.connected) {
      final currentServer = snap.dial?.serverId;
      if (currentServer != null &&
          best.servers.any((s) => s.id == currentServer)) {
        AppLog.info('quick connect auto: already on best region ${best.id}');
        snap = snap.copyWith(
          message: 'Already on ${snap.dial?.serverName ?? 'the best server'}.',
        );
        return;
      }
      await _switchServerOp(
        regionId: best.id,
        serverId: null,
        explicitTarget: false,
        pinTarget: false,
        expectedTeardown: teardownEpoch,
      );
      return;
    }
    // Not connected: reuse the live peer, switch it, or bind a fresh one
    // based on server truth (never a blind bind that would 409).
    await _autoConnectRegion(best, expectedTeardown: teardownEpoch);
  }
}
