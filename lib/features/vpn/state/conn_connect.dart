part of 'connection_controller.dart';

/// What a connect call should reach for.
///
/// The public entry points each map to one variant ([connect] →
/// [ReconcileTarget], [quickConnect] → [StickyTarget], [switchServer] →
/// [ExplicitTarget]); [_connectOp] resolves it and dispatches under one
/// mutex slot, so there is no decision taken across the lock boundary and no
/// discovery that a later teardown has to be re-checked against.
sealed class ConnectTarget {
  const ConnectTarget();
}

/// `connect()`: no discovery. Dial the pinned server (or the backend default)
/// and let the backend bind, replay, rotate, or move — the reconcile path.
final class ReconcileTarget extends ConnectTarget {
  const ReconcileTarget();
}

/// `quickConnect()`: sticky. A disconnected pin is discovery-validated (falling
/// back to auto when the server is gone, best-effort dialing it when discovery
/// fails); a connected pin moves straight to it. With nothing pinned, the
/// persisted target redials, else discovery auto-picks one-shot.
final class StickyTarget extends ConnectTarget {
  const StickyTarget();
}

/// `switchServer()`: move to a named region/server, pinning it unless [pin] is
/// false (a one-shot Auto move that leaves the state unpinned).
final class ExplicitTarget extends ConnectTarget {
  const ExplicitTarget({this.regionId, this.serverId, this.pin = true});
  final String? regionId;
  final String? serverId;
  final bool pin;
}

/// A resolved connect destination produced under the op mutex.
class _ResolvedTarget {
  const _ResolvedTarget.dial({this.regionId})
    : serverId = null,
      move = false,
      pin = false;
  const _ResolvedTarget.move({this.regionId, this.serverId, required this.pin})
    : move = true;

  /// True to run `_switchBody` (a move); false to run `_connectBody` (a dial).
  final bool move;

  /// One-shot region target; null falls back to `snap.serverId`.
  final String? regionId;

  /// One-shot server target; null falls back to `snap.serverId`.
  final String? serverId;

  /// Whether a move re-pins the bound server.
  final bool pin;
}

extension ConnectionConnect on ConnectionController {
  /// Lock-free connect body: caller must hold [_mutex] (see [_connectOp] and
  /// the no-device handover in [_switchBody], which stays under the switch
  /// slot instead of releasing and re-acquiring).
  ///
  /// A non-null [oneShotRegionId]/[oneShotServerId] dials that target for
  /// this call only (Auto re-pick): the pinned target in [snap] is left
  /// untouched, so an unpinned Auto stays unpinned.
  ///
  /// The backend owns every binding decision — bind when unbound, replay when
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
    // Routed via [_connectPost] like every other stored-key bind so timeout
    // and transport-vs-app error semantics stay in one place.
    final storedPub = await _device.publicKey();
    if (!sessionCurrent()) return;
    if (storedPub != null) {
      final dial = await _connectPost(
        id,
        storedPub,
        oneShotRegionId,
        oneShotServerId ?? snap.serverId,
      );
      if (!sessionCurrent()) return;
      await _startWith(_requireDial(dial, id), sessionEpoch: expectedSession);
      return;
    }
    // No stored key (an identity whose keypair was lost): generate one, ensure
    // the server binds it, and persist only after the POST succeeds so a
    // timeout can't clobber a working identity.
    final dial = await _bindFreshKey(
      id,
      regionId: oneShotRegionId,
      serverId: oneShotServerId,
      sessionEpoch: expectedSession,
    );
    if (!sessionCurrent()) return;
    await _startWith(dial, sessionEpoch: expectedSession);
  }

  /// Binds a fresh client key for [deviceId] and returns the dial params.
  /// Lock-free: caller must hold [_mutex]. The POST runs through
  /// [_connectPost] like every stored-key bind, so timeout and
  /// transport-vs-app error semantics stay in one place. The fresh keypair
  /// stays ephemeral until the POST succeeds and is only then persisted, so a
  /// timeout can't clobber the working identity. Explicit [regionId]/
  /// [serverId] dial that target for this call only; nulls fall back to the
  /// pinned server in [snap] (serverId only, both null = backend global
  /// auto-pick).
  Future<DialParams> _bindFreshKey(
    String deviceId, {
    String? regionId,
    String? serverId,
    int? sessionEpoch,
  }) async {
    final expectedSession = sessionEpoch ?? _sessionEpoch;
    bool sessionCurrent() => expectedSession == _sessionEpoch;
    if (!sessionCurrent()) {
      throw StateError('Session changed before connect bind.');
    }
    final kp = await _keys.generate();
    if (!sessionCurrent()) {
      throw StateError('Session changed before connect bind.');
    }
    AppLog.info(
      'connect bind device=${AppLog.redact(deviceId)} '
      'pubkey=${AppLog.redact(kp.publicKey)}',
    );
    final dial = await _connectPost(
      deviceId,
      kp.publicKey,
      regionId,
      serverId ?? snap.serverId,
    );
    if (!sessionCurrent()) {
      throw StateError('Session changed after connect bind.');
    }
    final bound = _requireDial(dial, deviceId);
    await _device.setKeypair(
      privateKey: kp.privateKey,
      publicKey: kp.publicKey,
    );
    if (!sessionCurrent()) {
      throw StateError('Session changed after key persistence.');
    }
    return bound;
  }

  /// The single locked connect/switch entry point.
  ///
  /// [target] is resolved under [_mutex], discovery included, so no decision is
  /// ever made across the lock boundary: a Disconnect tapped while this op runs
  /// simply queues behind it (FIFO) and runs next, which is why no
  /// teardown-epoch snapshot is threaded across a lock boundary any more.
  Future<void> _connectOp(ConnectTarget target) async {
    // Quick Connect no-ops while a connect is already working.
    if (target is StickyTarget && snap.phase == ConnPhase.working) return;
    if (target is ExplicitTarget) {
      // Clear any previous failure signal first: only an actual failure below
      // sets it again, so the benign same-target no-op never snacks.
      snap = snap.copyWith(opFailed: false);
      if (_skipSwitchToCurrentServer(target)) return;
      // A throttled client must not spend more of the shared limiter budget:
      // surface the countdown and skip the POST (a live tunnel stays up).
      if (_blockedByRateLimit('switch')) return;
    } else {
      // A throttled client must not run discovery or bind either: surface the
      // countdown and skip the network entirely.
      if (_blockedByRateLimit(
        target is StickyTarget ? 'quick connect' : 'connect',
      )) {
        return;
      }
      snap = snap.copyWith(opFailed: false);
    }
    final release = await _mutex.acquire(
      target is ExplicitTarget ? 'switch' : 'connect',
    );
    final sessionEpoch = _sessionEpoch;
    _ResolvedTarget? resolved;
    try {
      if (sessionEpoch != _sessionEpoch) return;
      resolved = await _resolveTarget(target, sessionEpoch);
      if (resolved == null) return;
      if (resolved.move) {
        // A move surfaces its own failures (see [_switchBody]).
        await _switchBody(
          regionId: resolved.regionId,
          serverId: resolved.serverId,
          pinTarget: resolved.pin,
        );
        return;
      }
      await _connectBody(
        oneShotRegionId: resolved.regionId,
        oneShotServerId: resolved.serverId,
        sessionEpoch: sessionEpoch,
      );
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      await _onConnectBindFailure(
        e,
        regionId: resolved?.regionId,
        serverId: resolved?.serverId,
        sessionEpoch: sessionEpoch,
      );
    } finally {
      release();
    }
  }

  /// True when [target] names the server the tunnel is already on: no API call
  /// or tunnel work is needed, but an explicit tap still carries pin intent
  /// (an Auto tap on the live server lands pinned so the Regions tab
  /// highlights it).
  bool _skipSwitchToCurrentServer(ExplicitTarget target) {
    final serverId = target.serverId;
    final live = snap.phase == ConnPhase.connected ? snap.dial?.serverId : null;
    if (serverId == null || serverId != live) return false;
    AppLog.info('switch skipped: already on $serverId');
    if (target.pin) {
      selectTarget(serverId: serverId, explicitTarget: target.pin);
    }
    snap = snap.copyWith(
      message:
          'Already connected to ${snap.dial?.serverName ?? 'this server'}.',
    );
    return true;
  }

  /// Resolves [target] to a concrete move or dial under the op mutex. Returns
  /// null when the op is done — a no-op with a message, or a failure already
  /// surfaced to [snap].
  Future<_ResolvedTarget?> _resolveTarget(
    ConnectTarget target,
    int sessionEpoch,
  ) async {
    switch (target) {
      case ReconcileTarget():
        return const _ResolvedTarget.dial();
      case ExplicitTarget():
        return _ResolvedTarget.move(
          regionId: target.regionId,
          serverId: target.serverId,
          pin: target.pin,
        );
      case StickyTarget():
        return _resolveSticky(sessionEpoch);
    }
  }

  /// Sticky (Quick Connect) resolution: in-memory pin, else the persisted
  /// target, else discovery auto-pick.
  Future<_ResolvedTarget?> _resolveSticky(int sessionEpoch) async {
    bool sessionCurrent() => sessionEpoch == _sessionEpoch;
    var pinned = snap.serverId;
    // Restart survival: the in-memory pin is gone but the persisted one
    // redials the same target.
    if (pinned == null) {
      try {
        final saved = await _device.lastTarget();
        if (!sessionCurrent()) return null;
        if (saved.serverId != null) {
          if (snap.phase == ConnPhase.connected) {
            // A move re-pins the bound server after the switch.
            return _ResolvedTarget.move(serverId: saved.serverId, pin: true);
          }
          selectTarget(
            serverId: saved.serverId,
            explicitTarget: saved.explicitTarget,
          );
          pinned = saved.serverId;
        }
      } catch (e) {
        if (!sessionCurrent()) return null;
        AppLog.error('quick connect saved target read failed', e);
      }
    }
    if (pinned != null) {
      if (snap.phase == ConnPhase.connected) {
        if (pinned == snap.dial?.serverId) {
          AppLog.info('switch skipped: already on $pinned');
          selectTarget(serverId: pinned, explicitTarget: true);
          snap = snap.copyWith(
            message:
                'Already connected to '
                '${snap.dial?.serverName ?? 'this server'}.',
          );
          return null;
        }
        return _ResolvedTarget.move(serverId: pinned, pin: true);
      }
      return _resolvePinned(pinned, sessionEpoch);
    }
    return _resolveAuto(sessionEpoch);
  }

  /// Discovery-validated connect onto a pinned server while disconnected: the
  /// pin is honored only while the server is still listed; gone → auto-pick
  /// and drop the stale pin; discovery failed → best-effort dial the pin, since
  /// the dial itself is the authoritative attempt.
  Future<_ResolvedTarget?> _resolvePinned(
    String pinned,
    int sessionEpoch,
  ) async {
    final List<Region> regions;
    try {
      regions = await _api.regions();
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return null;
      AppLog.error(
        'pinned connect discovery failed',
        asVpnError(e)?.message ?? e,
      );
      return const _ResolvedTarget.dial();
    }
    if (sessionEpoch != _sessionEpoch) return null;
    final stillListed = regions.any(
      (r) => r.servers.any((s) => s.id == pinned),
    );
    if (stillListed) {
      // Confirmed still serving: dial it exactly as before, keeping the pin.
      return const _ResolvedTarget.dial();
    }
    AppLog.info('pinned server gone -> auto-pick');
    // Abandoning a vanished server: clear the pin (in-memory + storage) so the
    // UI stops highlighting it and the next connect re-picks cleanly.
    selectTarget(serverId: null, explicitTarget: false);
    return _resolveAutoWith(regions, sessionEpoch);
  }

  /// Discovery for the unpinned (Auto) Quick Connect.
  Future<_ResolvedTarget?> _resolveAuto(int sessionEpoch) async {
    final List<Region> regions;
    try {
      regions = await _api.regions();
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return null;
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
      return null;
    }
    if (sessionEpoch != _sessionEpoch) return null;
    return _resolveAutoWith(regions, sessionEpoch);
  }

  /// Auto-picks the lowest-load region with capacity from [regions]: dials it
  /// one-shot when disconnected, moves to it one-shot when connected and the
  /// live server is outside it. Never pins, so later connects re-pick.
  Future<_ResolvedTarget?> _resolveAutoWith(
    List<Region> regions,
    int sessionEpoch,
  ) async {
    bool sessionCurrent() => sessionEpoch == _sessionEpoch;
    final best = autoPickRegion(regions);
    if (best == null) {
      // Every region with capacity is a candidate, so this is genuinely "no
      // capacity" and one message describes it. There is no platform lockout:
      // every server advertises `native`.
      AppLog.info('quick connect: no capacity');
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: 'No servers available right now.',
      );
      return null;
    }
    // Committing to Auto, so any pin the saved-target read could not act on
    // is stale — clear it regardless of how the connect below ends.
    await _clearPersistedPin(() => !sessionCurrent());
    if (!sessionCurrent()) return null;
    if (snap.phase == ConnPhase.connected) {
      final currentServer = snap.dial?.serverId;
      if (currentServer != null &&
          best.servers.any((s) => s.id == currentServer)) {
        AppLog.info('quick connect auto: already on best region ${best.id}');
        snap = snap.copyWith(
          message:
              'Already connected to '
              '${snap.dial?.serverName ?? 'the best server'}.',
        );
        return null;
      }
      // Auto stays unpinned: one-shot the picked region without pinning.
      return _ResolvedTarget.move(regionId: best.id, pin: false);
    }
    // Not connected: dial the picked target. The backend binds, reuses, or
    // moves the binding as needed, so no server read is required first.
    return _ResolvedTarget.dial(regionId: best.id);
  }

  /// Failure handling for the dial path of [_connectOp]: a key registered to
  /// another device retries once with a fresh keypair (keeping the selected
  /// target, or the one-shot Auto pick); a 404 wipes the identity so the next
  /// tap reprovisions.
  Future<void> _onConnectBindFailure(
    Object e, {
    required String? regionId,
    required String? serverId,
    required int sessionEpoch,
  }) async {
    final vpnErr = asVpnError(e);
    AppLog.error(
      'connect failed kind=${vpnErr?.kind ?? e.runtimeType}',
      vpnErr?.message ?? e,
    );
    final rateWait = _noteRateLimit(vpnErr);
    if (vpnErr?.kind == ApiErrorKind.keyInUse) {
      AppLog.info('connect key-in-use -> retry once with fresh key');
      final retryId = await _device.deviceId();
      if (sessionEpoch != _sessionEpoch) return;
      if (retryId != null) {
        try {
          // Same fresh-key bind as the no-stored-key path (generate, POST,
          // persist only on success): shared so the two cannot drift.
          final dial = await _bindFreshKey(
            retryId,
            regionId: regionId,
            serverId: serverId,
            sessionEpoch: sessionEpoch,
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
}
