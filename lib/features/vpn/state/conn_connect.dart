part of 'connection_controller.dart';

extension ConnectionConnect on ConnectionController {
  /// Lock-free connect body: caller must hold [_mutex] (see [connect] and
  /// the no-device handover in [switchServer], which stays under the switch
  /// slot instead of releasing and re-acquiring).
  ///
  /// A non-null [oneShotRegionId]/[oneShotServerId] dials that target for
  /// this call only (Auto re-pick): the pinned target in [snap] is left
  /// untouched, so an unpinned Auto stays unpinned.
  ///
  /// The backend owns every peer decision — bind when peerless, replay when
  /// we already hold the key on the target, rotate when only the key differs,
  /// move when a target is named — so this is a single `POST …/connect` on the
  /// key in the store. There is no server-truth probe and no already-bound
  /// reconciliation to run.
  Future<void> _connectBody({
    String? oneShotRegionId,
    String? oneShotServerId,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) return;
    var id = await _device.deviceId();
    if (!sessionCurrent()) return;
    AppLog.info('connect start gen=$_tunnelEpoch device=${AppLog.redact(id)}');
    if (id == null) {
      // Freshly provisioned devices come back bound; dial straight away.
      // [_provision] is lock-free and runs under this op's mutex slot.
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
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Connecting…',
        recoveryAction: null,
        recoveryReason: null,
        recoveryDetail: null,
      );
      await _startWith(provisioned, sessionEpoch: expectedSession);
      return;
    }
    snap = snap.copyWith(
      phase: ConnPhase.working,
      message: 'Connecting…',
      recoveryAction: null,
      recoveryReason: null,
      recoveryDetail: null,
    );
    // Ensure the server holds the key we have, on the requested target (or
    // where we already are when no target is named) — one call, no probe.
    final storedPub = await _device.publicKey();
    if (!sessionCurrent()) return;
    if (storedPub != null) {
      final dial = await _api.connect(
        deviceId: id,
        publicKey: storedPub,
        serverId: oneShotServerId ?? snap.serverId,
        regionId: oneShotRegionId,
      );
      if (!sessionCurrent()) return;
      await _startWith(dial, sessionEpoch: expectedSession);
      return;
    }
    // No stored key (an identity whose keypair was lost): generate one, ensure
    // the server binds it, and persist only after the POST succeeds so a
    // timeout can't clobber a working identity.
    final dial = await _bindFreshPeer(
      id,
      regionId: oneShotRegionId,
      serverId: oneShotServerId,
      sessionEpoch: expectedSession,
    );
    if (!sessionCurrent()) return;
    await _startWith(dial, sessionEpoch: expectedSession);
  }

  /// Binds a fresh client key for [deviceId] and returns the dial params.
  /// Lock-free: caller must hold [_mutex]. The fresh keypair stays
  /// ephemeral until the POST succeeds and is only then persisted, so a
  /// timeout can't clobber the working identity. Explicit [regionId]/
  /// [serverId] dial that target for this call only; nulls fall back to the
  /// pinned server in [snap] (serverId only, both null = backend global
  /// auto-pick).
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
      regionId: regionId,
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

  /// Connect: ensure the server holds our key on the selected target, then
  /// start the tunnel. [oneShotRegionId]/[oneShotServerId] dial that target for
  /// this call only without touching the pinned target (Auto re-pick).
  ///
  /// Connect is idempotent on the key we hold, so a reconnect is the same call
  /// as a first connect; the backend binds, replays, rotates, or moves as
  /// needed. A key already registered to *another* device is retried once with
  /// a fresh keypair; a 404 means the device is gone, so the identity is wiped
  /// and the next tap reprovisions.
  Future<void> _connectOp({
    String? oneShotRegionId,
    String? oneShotServerId,
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
              regionId: oneShotRegionId,
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
        try {
          await _wipeDevice();
        } catch (e) {
          AppLog.error('connect clear device failed', e);
        }
      }
      if (sessionEpoch != _sessionEpoch) return;
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: rateWait != null
            ? _rateLimitMessage(rateWait)
            : failureReason(vpnErr, e),
        opFailed: true,
      );
    } finally {
      release();
    }
  }

  /// Drops a leftover persisted pin once Quick Connect commits to Auto.
  ///
  /// A pin in [snap] is redialed as-is, and a pin only in storage is
  /// rehydrated by the saved-target read. So the Auto branch is reached with
  /// a pin still in storage only when that read failed (a locked keychain) —
  /// and a pin left behind there is the one shape that outlives the session:
  /// the next cold start rehydrates it through [_restoreColdSession] and the
  /// app sticks to a target the user has since left behind.
  ///
  /// Deliberately independent of how the connect that follows ends: the
  /// decision to be in Auto mode, not that connect's outcome, is what a
  /// persisted pin has to agree with. [isSuperseded] guards the read and the
  /// write: a Disconnect or a newer session landing in between may have
  /// re-pinned, and an abandoned op must not clear that. An already-unpinned
  /// store is left alone (no needless secure-storage write).
  Future<void> _clearPersistedPin(bool Function() isSuperseded) async {
    if (isSuperseded()) return;
    try {
      final saved = await _device.lastTarget();
      if (saved.serverId == null) return;
      if (isSuperseded()) return;
      await _device.setLastTarget(serverId: null, explicitTarget: false);
    } catch (e) {
      AppLog.error('auto connect clear persisted pin failed', e);
    }
  }

  /// Quick Connect shared by the Home power button and the Regions
  /// Quick-Connect tile.
  ///
  /// Sticky when a server is pinned: it is discovery-validated via
  /// [_pinnedConnectOp] (or [switchServer] when connected). When nothing is
  /// pinned (Auto, e.g. after [selectAuto]) the lowest-load region with
  /// capacity ([autoPickRegion]) is dialed one-shot via [_connectAutoWith]:
  /// the state stays unpinned, so every Auto connect re-picks fresh and the
  /// next disconnect → Connect moves again instead of sticking to the old
  /// server. While connected, an Auto call no-ops when the live server is
  /// already inside the best region, else it moves one-shot without pinning.
  /// Delegates without holding the mutex: connected → [switchServer]
  /// (keeps the same-target no-op), otherwise discovery then
  /// reuse/move/connect. Never pre-pins before a switch: that would trip
  /// the same-target skip check. Committing to Auto also drops any pin left in
  /// storage by an earlier session ([_clearPersistedPin]) — before the
  /// connected one-shot switch and the already-on-best-region no-op, not just
  /// the first connect of a session. The whole discovery sequence is
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
    // Sticky reconnect: the last selected server redials, so disconnect →
    // Connect stays on the same target once discovery confirms it still
    // exists.
    if (snap.serverId != null) {
      if (snap.phase == ConnPhase.connected) {
        await _switchServerOp(
          regionId: null,
          serverId: snap.serverId,
          expectedTeardown: teardownEpoch,
        );
        return;
      }
      await _pinnedConnectOp(expectedTeardown: teardownEpoch);
      return;
    }
    // Restart survival: the in-memory pin is gone but the persisted one
    // redials the same target.
    try {
      final saved = await _device.lastTarget();
      // Another op may have taken over while reading the store.
      if (superseded() || snap.phase == ConnPhase.working) {
        return;
      }
      if (saved.serverId != null) {
        if (snap.phase == ConnPhase.connected) {
          await _switchServerOp(
            regionId: null,
            serverId: saved.serverId,
            expectedTeardown: teardownEpoch,
          );
          return;
        }
        selectTarget(
          serverId: saved.serverId,
          explicitTarget: saved.explicitTarget,
        );
        await _pinnedConnectOp(expectedTeardown: teardownEpoch);
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
            : failureReason(vpnErr, e),
        opFailed: true,
      );
      return;
    }
    if (superseded()) return;
    await _connectAutoWith(regions, expectedTeardown: teardownEpoch);
  }

  /// Discovery-validated connect onto the pinned server.
  ///
  /// Tapping Connect while disconnected with a server pinned re-fetches the
  /// region list every time (the backend allows 60s client caching, but a
  /// re-pick must not trust a stale cache). The pin is honored only while the
  /// server is still listed:
  ///  - listed → dial it as usual (pin kept);
  ///  - gone → fall back to Auto ([_connectAutoWith]) and drop the stale pin;
  ///  - discovery failed → best-effort dial the pin as-is, since the dial
  ///    itself is the authoritative attempt.
  Future<void> _pinnedConnectOp({int? expectedTeardown}) async {
    final sessionEpoch = _sessionEpoch;
    final teardownEpoch = expectedTeardown ?? _teardownEpoch;
    bool superseded() =>
        sessionEpoch != _sessionEpoch || teardownEpoch != _teardownEpoch;
    final pinned = snap.serverId;
    if (pinned == null) {
      await _connectOp(expectedTeardown: teardownEpoch);
      return;
    }
    final List<Region> regions;
    try {
      regions = await _api.regions();
    } catch (e) {
      if (superseded()) return;
      AppLog.error(
        'pinned connect discovery failed',
        asVpnError(e)?.message ?? e,
      );
      await _connectOp(expectedTeardown: teardownEpoch);
      return;
    }
    if (superseded()) return;
    final stillListed = regions.any(
      (r) => r.servers.any((s) => s.id == pinned),
    );
    if (stillListed) {
      // Confirmed still serving: dial it exactly as before, keeping the pin.
      await _connectOp(expectedTeardown: teardownEpoch);
      return;
    }
    AppLog.info('pinned server gone -> auto-pick');
    // Abandoning a vanished server: clear the pin (in-memory + storage) so
    // the UI stops highlighting it and the next connect re-picks cleanly.
    selectTarget(serverId: null, explicitTarget: false);
    if (superseded()) return;
    await _connectAutoWith(regions, expectedTeardown: teardownEpoch);
  }

  /// Dials Auto against a freshly fetched [regions] list: the lowest-load
  /// region with capacity, one-shot (never pins). Shared by the unpinned
  /// Quick Connect path and the stale-pin fallback.
  Future<void> _connectAutoWith(
    List<Region> regions, {
    int? expectedTeardown,
  }) async {
    final sessionEpoch = _sessionEpoch;
    final teardownEpoch = expectedTeardown ?? _teardownEpoch;
    bool superseded() =>
        sessionEpoch != _sessionEpoch || teardownEpoch != _teardownEpoch;
    final best = autoPickRegion(regions);
    if (best == null) {
      // Every region with capacity is a candidate, so this is genuinely "no
      // capacity" and one message describes it. There used to be a second
      // possibility here — no region this build could serve a conf for — and it
      // is gone: every server advertises `native`, so there is no region a
      // platform can be locked out of.
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
    // Committing to Auto, so any pin the saved-target read could not act on
    // is stale — clear it before the connect below, and do so regardless of
    // how that connect ends.
    await _clearPersistedPin(superseded);
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
          message:
              'Already connected to ${snap.dial?.serverName ?? 'the best server'}.',
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
    // Not connected: dial the picked target. The backend binds, reuses, or
    // moves the peer as needed, so no server-truth read is required first.
    await _connectOp(oneShotRegionId: best.id, expectedTeardown: teardownEpoch);
  }
}
