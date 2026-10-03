part of 'connection_controller.dart';

extension ConnectionSwitch on ConnectionController {
  Future<void> _switchServerOp({
    required String? regionId,
    required String? serverId,
    // False only for the auto-picked Quick Connect path: an automatic
    // region choice must not constrain later failover to that region.
    bool explicitTarget = true,
    // False for one-shot Auto moves: the picked target is dialed without
    // pinning, so the state stays unpinned and later connects re-pick.
    bool pinTarget = true,
    // Quick Connect's snapshot of [_teardownEpoch]: a Disconnect that landed
    // during its lock-free discovery must win over this queued switch.
    int? expectedTeardown,
  }) async {
    // Clear any previous failure signal first: only an actual failure below
    // sets it again, so the benign same-target no-op never snacks.
    snap = snap.copyWith(opFailed: false);
    // Skip only against a target the tunnel is actually on. A pin outlives
    // the peer it names — it is restored from storage on every cold start —
    // so a restored pin can name a server the live dial is not on, and
    // skipping there would swallow a real tap while reporting "already
    // connected" for a tunnel that is somewhere else. A server request
    // therefore compares against the live dial, and only while one is up;
    // nothing is "already connected" below that, and the backend's
    // already-bound 409 is answered with a config reload in the catch, so a
    // missed skip costs one request rather than a stranded tunnel.
    final live = snap.phase == ConnPhase.connected ? snap.dial?.serverId : null;
    final sameServer = serverId != null && serverId == live;
    if (sameServer) {
      AppLog.info('switch skipped: already on $serverId');
      // No tunnel work needed, but an explicit tap still carries pin intent:
      // Auto (unpinned) tapping the live server must land pinned so the
      // Regions tab highlights it. One-shot Auto moves (pinTarget false)
      // stay unpinned.
      if (pinTarget) {
        selectTarget(serverId: serverId, explicitTarget: explicitTarget);
      }
      snap = snap.copyWith(
        message:
            'Already connected to ${snap.dial?.serverName ?? 'this server'}.',
      );
      return;
    }
    final release = await _mutex.acquire('switch');
    final sessionEpoch = _sessionEpoch;
    final oldDial = snap.dial;
    final wasConnected = snap.phase == ConnPhase.connected;
    // Snapshot the working identity: the fresh key stays ephemeral until
    // the POST succeeds, so on failure this is what the store must hold.
    // Read inside the `try` below so a throwing secure-storage read (locked
    // keychain) still reaches `finally { release() }` and cannot wedge the
    // mutex forever. Null when the read never completed: nothing was
    // mutated, so [_restoreKeypair] correctly no-ops.
    String? oldPriv;
    String? oldPub;
    // True once a transport failure leaves the server-side outcome
    // uncertain (a timed-out POST may still have bound the key). Declared
    // outside `try` so the `catch` recovery can read it.
    var ambiguous = false;
    // True once `POST …/switch` returned a dial: the server has already
    // committed the fresh key, so a later failure (e.g. the tunnel restart)
    // must keep the new store identity instead of rolling back to the old
    // key, which the server no longer accepts.
    var serverCommitted = false;
    // True once the fallback path stopped the tunnel: the UI must not
    // claim to still be connected on the old server when no tunnel runs.
    var tunnelDown = false;
    // Device identity for the peerless-switch recovery in `catch` (a peer
    // GC'd after disconnect leaves a device with no peer, which the
    // backend's /switch POST rejects with 404).
    String? id;
    try {
      // Quick Connect snapshotted [_teardownEpoch] before its lock-free
      // discovery: a Disconnect that landed while this switch was queued must
      // win. Checked first so a superseded switch surfaces nothing.
      if (expectedTeardown != null && expectedTeardown != _teardownEpoch) {
        return;
      }
      // A throttled client must not spend more of the shared limiter budget:
      // surface the countdown and skip the POST (a live tunnel stays up).
      if (_blockedByRateLimit('switch')) return;
      oldPriv = await _device.privateKey();
      oldPub = await _device.publicKey();
      id = await _device.deviceId();
      if (sessionEpoch != _sessionEpoch) return;
      AppLog.info(
        'switch start gen=$_tunnelEpoch device=${AppLog.redact(id)} '
        'region=${regionId ?? '<null>'} server=${serverId ?? '<null>'}',
      );
      if (id == null) {
        // No device yet: provision+connect inline under this op's mutex
        // slot (both inners are lock-free), so no other op can interleave
        // between them. Never release/re-acquire here: that breaks the
        // serialization the mutex exists to guarantee.
        // Replace any stale pin with the requested target first: a
        // region-targeted switch has no server yet, so this clears the old
        // one (otherwise `_provision` would carry it as `snap.serverId`);
        // the connect below adopts the bound dial and pins it.
        if (pinTarget) {
          selectTarget(serverId: serverId, explicitTarget: explicitTarget);
        }
        await _provision(
          regionId: regionId,
          serverId: serverId,
          sessionEpoch: sessionEpoch,
        );
        await _connectBody(sessionEpoch: sessionEpoch);
        if (sessionEpoch != _sessionEpoch) return;
        if (pinTarget) {
          final dial = snap.dial;
          if (dial != null) {
            selectTarget(
              serverId: dial.serverId,
              explicitTarget: explicitTarget,
            );
          }
        }
        return;
      }
      snap = snap.copyWith(phase: ConnPhase.working, message: 'Switching…');
      final deviceId = id;
      if (_peerReleasedLocally) {
        // This session released the device's peer (see
        // [ConnectionLifecycle._disconnectBody]) and has bound none since, so
        // there is nothing to move: `POST …/switch` on a peerless device
        // answers 404 PEER_NOT_FOUND, and the catch below recovers by binding a
        // fresh peer on the new target anyway. Take that recovery directly
        // instead of spending the request and the round trip to be told what
        // this client already knows. Everything after it — the pin, the key
        // persistence, `_startWith` — is that same recovery, run once here
        // rather than twice.
        AppLog.info(
          'switch peerless (released locally) -> bind fresh peer on new target',
        );
        if (pinTarget) {
          selectTarget(serverId: serverId, explicitTarget: explicitTarget);
        }
        final fresh = await _bindFreshPeer(
          deviceId,
          regionId: regionId,
          serverId: serverId,
          sessionEpoch: sessionEpoch,
        );
        if (sessionEpoch != _sessionEpoch) return;
        // The peer is the server's now: a failed restart must not roll the
        // store back to the pair the disconnect left behind.
        serverCommitted = true;
        await _startWith(fresh, sessionEpoch: sessionEpoch);
        if (sessionEpoch != _sessionEpoch) return;
        if (pinTarget) {
          selectTarget(
            serverId: fresh.serverId,
            explicitTarget: explicitTarget,
          );
        }
        return;
      }
      final kp = await _keys.generate();
      if (sessionEpoch != _sessionEpoch) return;
      // Probe through the live tunnel first (loopback APIs bypass it without
      // a short timeout, but still without stopping). The tunnel is stopped
      // only when the backend is unreachable through the current path.
      final result = await _postViaTunnelOrDirect(
        post: ({Duration? timeout}) => _switchPost(
          deviceId,
          kp.publicKey,
          regionId,
          serverId,
          timeout: timeout,
        ),
        wasConnected: wasConnected,
        stopLabel: 'switch',
        onFallbackStart: () {
          if (sessionEpoch == _sessionEpoch) {
            snap = snap.copyWith(
              phase: ConnPhase.working,
              message: 'Retrying over direct connection…',
            );
          }
        },
        onFallbackEnd: () {
          if (sessionEpoch == _sessionEpoch) {
            snap = snap.copyWith(
              phase: ConnPhase.working,
              message: 'Switching…',
            );
          }
        },
      );
      if (sessionEpoch != _sessionEpoch) return;
      tunnelDown = result.tunnelDown;
      // The in-tunnel probe failed at transport level: the server-side
      // outcome is unknown, so a double failure must say so below.
      ambiguous = result.probeTransportFailure;
      final dial = result.dial;
      if (dial == null) {
        // Every attempt failed with a transport error: keep the old tunnel
        // up and report, instead of stranding the user with nothing running.
        ambiguous = true;
        throw _ambiguousFailure(
          '/vpn-devices/$deviceId/switch',
          'Switch request failed. Check your connection and retry.',
        );
      }
      // The POST was accepted: the server's active peer is now the fresh key.
      // Any failure from here keeps that identity.
      serverCommitted = true;
      // The tunnel may still be up (in-tunnel success): never run two live
      // tunnels (Windows/Wintun route wedge). Skipped when the fallback path
      // already stopped it. Track the stop so a failed restart below surfaces
      // `error` instead of claiming the old target is still connected.
      if (!tunnelDown) {
        await _stopTunnel('switch-restart');
        if (sessionEpoch != _sessionEpoch) return;
        tunnelDown = true;
      }
      // Only now does the new key become the stored identity: it matches the
      // freshly bound server-side peer.
      await _device.setKeypair(
        privateKey: kp.privateKey,
        publicKey: kp.publicKey,
      );
      if (sessionEpoch != _sessionEpoch) return;
      await _startWith(dial, sessionEpoch: sessionEpoch);
      if (sessionEpoch != _sessionEpoch) return;
      // Record the exact bound server so the Regions tab highlights it and
      // reconnects keep it (a region-targeted switch pins the server the
      // backend picked). One-shot Auto moves skip this so the state stays
      // unpinned.
      if (pinTarget) {
        selectTarget(
          serverId: serverId ?? dial.serverId,
          explicitTarget: explicitTarget,
        );
      }
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error(
        'switch failed kind=${vpnErr?.kind ?? e.runtimeType}',
        vpnErr?.message ?? e,
      );
      if (vpnErr?.kind == ApiErrorKind.alreadyConnected && id != null) {
        // Already bound to the requested server (typical: restart without
        // disconnect lost the pinned target, so the skip-check missed and
        // the POST 409s with SERVER_CONFLICT). The ephemeral switch key
        // was never persisted, so the store still holds the working key
        // matching the server-side peer: just load config and start.
        AppLog.info('switch already-bound -> load config and start');
        try {
          if (!tunnelDown &&
              (snap.phase == ConnPhase.connected || wasConnected)) {
            await _stopTunnel('switch');
            if (sessionEpoch != _sessionEpoch) return;
            tunnelDown = true;
          }
          final reconciled = await _configReconciled(
            id,
            sessionEpoch: sessionEpoch,
          );
          if (sessionEpoch != _sessionEpoch) return;
          final dial = reconciled.dial;
          // Server truth is now the stored identity (a mismatch above would
          // have rotated and persisted): a later failure must not roll back.
          serverCommitted = true;
          await _startWith(dial, sessionEpoch: sessionEpoch);
          if (sessionEpoch != _sessionEpoch) return;
          // A one-shot Auto move recovers onto the live dial without
          // pinning; explicit moves re-pin the canonical target (user
          // intent, even though the post-success pin hasn't landed yet).
          if (pinTarget) {
            _pinCanonicalTarget(dial, preserveAuto: false);
          }
          if (sessionEpoch != _sessionEpoch) return;
          return;
        } catch (e2) {
          if (sessionEpoch != _sessionEpoch) return;
          AppLog.error('switch already-bound reload failed', e2);
          _noteRateLimit(asVpnError(e2));
          // Fall through to the failure surfacing below.
        }
      }
      if (vpnErr?.kind == ApiErrorKind.noActivePeer && id != null) {
        // The device exists but holds no peer, and this session did not release
        // it: the backend GC'd it while idle, or the app restarted with the
        // release unconfirmed. There is nothing to switch, so bind a fresh peer
        // directly on the requested target instead of failing. The locally-known
        // case never reaches here — it is served before the POST (see
        // [_peerReleasedLocally]), so this is the one recovery path.
        AppLog.info('switch peerless -> bind fresh peer on new target');
        try {
          // [_startWith] only stops a previous tunnel when already
          // `connected`; the switch may have left one running while
          // `working`, so stop explicitly to never run two live tunnels
          // and so the bind POST travels over the direct network.
          if (!tunnelDown) {
            await _stopTunnel('switch');
            if (sessionEpoch != _sessionEpoch) return;
            tunnelDown = true;
          }
          // Replace any stale pin so a region-targeted bind can't fall back
          // to it via `_bindFreshPeer`'s `snap.serverId` default.
          if (pinTarget) {
            selectTarget(serverId: serverId, explicitTarget: explicitTarget);
          }
          final fresh = await _bindFreshPeer(
            id,
            regionId: regionId,
            serverId: serverId,
            sessionEpoch: sessionEpoch,
          );
          if (sessionEpoch != _sessionEpoch) return;
          // [_bindFreshPeer] persisted the freshly bound key: the server holds
          // it now, so a failed restart must not roll back to the old pair.
          serverCommitted = true;
          await _startWith(fresh, sessionEpoch: sessionEpoch);
          if (sessionEpoch != _sessionEpoch) return;
          if (pinTarget) {
            selectTarget(
              serverId: fresh.serverId,
              explicitTarget: explicitTarget,
            );
          }
          return;
        } catch (e2) {
          if (sessionEpoch != _sessionEpoch) return;
          AppLog.error('switch peerless bind failed', e2);
          _noteRateLimit(asVpnError(e2));
          // Fall through to the failure surfacing below.
        }
      }
      // Only a failure before the POST returned may roll the store back: the
      // server's active peer then still holds the old key. Once it committed
      // the fresh key, restoring the old pair would diverge permanently.
      if (!serverCommitted) {
        await _restoreKeypair(
          oldPriv: oldPriv,
          oldPub: oldPub,
          label: 'switch',
          sessionEpoch: sessionEpoch,
        );
      }
      // A double transport failure leaves the server-side outcome uncertain,
      // so say so: a Connect reconciles via config/connect. The fallback path
      // stops the tunnel before the direct POST, so a failure there means no
      // tunnel is running (see [_surfaceOpFailure]).
      _surfaceOpFailure(
        e: e,
        vpnErr: vpnErr,
        ambiguous: ambiguous,
        tunnelDown: tunnelDown,
        wasConnected: wasConnected,
        oldDial: oldDial,
        ambiguousPrefix:
            'Switch status unknown (request may have reached the server).',
        cleanPrefix:
            'Switch failed, still on '
            '${oldDial?.serverName ?? 'the old server'}.',
        sessionEpoch: sessionEpoch,
      );
    } finally {
      release();
    }
  }

  /// Rotate the WireGuard key in place: same server and overlay IP, the
  /// peer moves to a fresh key and the tunnel restarts on the new config.
  /// Manual calls surface errors; automatic (background) calls fail silent
  /// while the tunnel stays up — the next poll tick retries since
  /// [_pollsSinceRotate] only resets on success. A failure after the tunnel
  /// was stopped surfaces `error` even for auto (no tunnel is running).
  Future<void> _rotateKeysOp({bool auto = false}) async {
    // Respect an active 429 cooldown before taking the op lock: a manual
    // rotate surfaces the countdown, a background one just waits for a later
    // poll tick (its retry cadence is the poll interval).
    if (auto) {
      if (_rateLimitRemaining != null) {
        AppLog.info('auto-rotate skipped (rate limited)');
        return;
      }
    } else if (_blockedByRateLimit('rotate')) {
      return;
    }
    final release = await _mutex.acquire(auto ? 'auto-rotate' : 'rotate');
    if (snap.phase != ConnPhase.connected || snap.dial == null) {
      AppLog.info(
        'rotate skipped (${auto ? 'auto' : 'manual'} session not connected)',
      );
      if (!auto) {
        snap = snap.copyWith(
          phase: ConnPhase.error,
          message: 'No connected tunnel to rotate. Connect first.',
          opFailed: true,
        );
      }
      release();
      return;
    }
    final oldDial = snap.dial!;
    const wasConnected = true;
    final sessionEpoch = _sessionEpoch;
    // Snapshot the working identity; read inside the `try` so a throwing
    // secure-storage read still releases the mutex (see _switchServerOp).
    String? oldPriv;
    String? oldPub;
    // True once a transport failure leaves the server-side outcome
    // uncertain (a timed-out POST may still have bound the key).
    var ambiguous = false;
    // True once `POST …/rotate-keys` returned: the server holds the fresh
    // key, so a later failure must keep it instead of restoring the old pair.
    var serverCommitted = false;
    // See switchServer: a failure after the fallback stop leaves no tunnel
    // running and must surface `error`.
    var tunnelDown = false;
    try {
      oldPriv = await _device.privateKey();
      oldPub = await _device.publicKey();
      final id = await _device.deviceId();
      if (sessionEpoch != _sessionEpoch) return;
      if (id == null) {
        if (!auto) {
          snap = snap.copyWith(
            phase: ConnPhase.error,
            message: 'No device. Connect first to provision one.',
          );
        }
        return;
      }
      AppLog.info('rotate start device=${AppLog.redact(id)} auto=$auto');
      if (!auto) {
        snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Rotating key…',
        );
      }
      final kp = await _keys.generate();
      if (sessionEpoch != _sessionEpoch) return;
      final deviceId = id;
      // Probe through the live tunnel first; stop only when the backend is
      // unreachable through the current path (same rule as switch).
      final result = await _postViaTunnelOrDirect(
        post: ({Duration? timeout}) =>
            _rotatePost(deviceId, kp.publicKey, timeout: timeout),
        wasConnected: wasConnected,
        stopLabel: 'rotate',
        onFallbackStart: auto
            ? null
            : () {
                if (sessionEpoch != _sessionEpoch) return;
                snap = snap.copyWith(
                  phase: ConnPhase.working,
                  message: 'Retrying over direct connection…',
                );
              },
        onFallbackEnd: auto
            ? null
            : () {
                if (sessionEpoch != _sessionEpoch) return;
                snap = snap.copyWith(
                  phase: ConnPhase.working,
                  message: 'Rotating…',
                );
              },
      );
      if (sessionEpoch != _sessionEpoch) return;
      tunnelDown = result.tunnelDown;
      ambiguous = result.probeTransportFailure;
      final dial = result.dial;
      if (dial == null) {
        // Every attempt failed with a transport error while the old tunnel
        // may still be up: keep it (auto retries on the next tick).
        ambiguous = true;
        throw _ambiguousFailure(
          '/vpn-devices/$deviceId/rotate-keys',
          'Rotate request failed. Check your connection and retry.',
        );
      }
      // The POST was accepted: the server's active peer now holds the fresh
      // key. Any failure from here keeps that identity.
      serverCommitted = true;
      if (sessionEpoch != _sessionEpoch) return;
      if (!tunnelDown) {
        await _stopTunnel('rotate-restart');
        if (sessionEpoch != _sessionEpoch) return;
        tunnelDown = true;
      }
      await _device.setKeypair(
        privateKey: kp.privateKey,
        publicKey: kp.publicKey,
      );
      if (sessionEpoch != _sessionEpoch) return;
      await _startWith(dial, sessionEpoch: sessionEpoch);
      if (sessionEpoch != _sessionEpoch) return;
      _pollsSinceRotate = 0;
      AppLog.info('rotate ok device=${AppLog.redact(id)} auto=$auto');
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error(
        'rotate failed kind=${vpnErr?.kind ?? e.runtimeType} auto=$auto',
        vpnErr?.message ?? e,
      );
      _noteRateLimit(vpnErr);
      // Only a failure before the POST returned may roll the store back; a
      // committed rotation already moved the server-side peer.
      if (!serverCommitted) {
        await _restoreKeypair(
          oldPriv: oldPriv,
          oldPub: oldPub,
          label: 'rotate',
          sessionEpoch: sessionEpoch,
        );
      }
      // A failure after the fallback stop leaves no tunnel running: it must
      // surface `error` even for background rotations, otherwise the UI stays
      // `connected` with the old dial while nothing runs. Only a failure with
      // the tunnel still up stays silent for auto (next poll tick retries).
      if (auto && !tunnelDown) return;
      _surfaceOpFailure(
        e: e,
        vpnErr: vpnErr,
        ambiguous: ambiguous,
        tunnelDown: tunnelDown,
        wasConnected: wasConnected,
        oldDial: oldDial,
        ambiguousPrefix:
            'Rotate status unknown (request may have reached the server).',
        cleanPrefix: 'Rotate failed, still on the old key.',
        sessionEpoch: sessionEpoch,
      );
    } finally {
      release();
    }
  }
}
