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
  }) async {
    // Clear any previous failure signal first: only an actual failure below
    // sets it again, so the benign same-target no-op never snacks.
    snap = snap.copyWith(opFailed: false);
    // Both sides compare against the same source (the pinned target): the
    // target always holds exactly one side, so a stale value on the other
    // side can never leak into a switch or suppress a legitimate one.
    final sameServer = serverId != null && serverId == snap.serverId;
    final sameRegion = regionId != null && regionId == snap.regionId;
    if (sameServer || sameRegion) {
      AppLog.info(
        'switch skipped: already on ${serverId ?? 'region=$regionId'}',
      );
      snap = snap.copyWith(
        message: 'Already on ${snap.dial?.serverName ?? 'this server'}.',
      );
      return;
    }
    final release = await _mutex.acquire('switch');
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
    // True once the fallback path stopped the tunnel: the UI must not
    // claim to still be connected on the old server when no tunnel runs.
    var tunnelDown = false;
    // Device identity for the peerless-switch recovery in `catch` (a peer
    // GC'd after disconnect leaves a device with no active peer, which the
    // backend's /switch POST rejects with 404).
    String? id;
    try {
      // A throttled client must not spend more of the shared limiter budget:
      // surface the countdown and skip the POST (a live tunnel stays up).
      if (_blockedByRateLimit('switch')) return;
      oldPriv = await _device.privateKey();
      oldPub = await _device.publicKey();
      id = await _device.deviceId();
      AppLog.info(
        'switch start gen=$_tunnelEpoch device=${AppLog.redact(id)} '
        'region=${regionId ?? '<null>'} server=${serverId ?? '<null>'}',
      );
      if (id == null) {
        // No device yet: provision+connect inline under this op's mutex
        // slot (both inners are lock-free), so no other op can interleave
        // between them. Never release/re-acquire here: that breaks the
        // serialization the mutex exists to guarantee.
        if (pinTarget) {
          selectTarget(
            regionId: regionId,
            serverId: serverId,
            explicitTarget: explicitTarget,
          );
        }
        await _provision(regionId: regionId, serverId: serverId);
        await _connectBody();
        return;
      }
      snap = snap.copyWith(phase: ConnPhase.working, message: 'Switching…');
      final kp = await _keys.generate();
      final deviceId = id;
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
        onFallbackStart: () => snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Retrying over direct connection…',
        ),
        onFallbackEnd: () => snap = snap.copyWith(
          phase: ConnPhase.working,
          message: 'Switching…',
        ),
      );
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
      // The tunnel may still be up (in-tunnel success): never run two live
      // tunnels (Windows/Wintun route wedge). Skipped when the fallback path
      // already stopped it.
      if (!tunnelDown) await _stopTunnel('switch-restart');
      // Only now does the new key become the stored identity: it matches the
      // freshly bound server-side peer.
      await _device.setKeypair(
        privateKey: kp.privateKey,
        publicKey: kp.publicKey,
      );
      await _startWith(dial);
      // Record the exact new target (one side is null by contract) so the
      // Regions tab highlights it and reconnects keep it. One-shot Auto
      // moves skip this so the state stays unpinned.
      if (pinTarget) {
        selectTarget(
          regionId: regionId,
          serverId: serverId,
          explicitTarget: explicitTarget,
        );
      }
    } catch (e) {
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
            tunnelDown = true;
          }
          final dial = await _api.config(id);
          await _startWith(dial);
          // A one-shot Auto move recovers onto the live dial without
          // pinning; explicit moves re-pin the canonical target (user
          // intent, even though the post-success pin hasn't landed yet).
          if (pinTarget) {
            await _pinCanonicalTarget(
              dial,
              regionRequest: regionId != null,
              preserveAuto: false,
            );
          }
          return;
        } catch (e2) {
          AppLog.error('switch already-bound reload failed', e2);
          _noteRateLimit(asVpnError(e2));
          // Fall through to the failure surfacing below.
        }
      }
      if (vpnErr?.kind == ApiErrorKind.noActivePeer && id != null) {
        // The device exists but holds no peer (disconnected or GC'd while
        // idle): there is nothing to switch, so bind a fresh peer directly
        // on the requested target instead of failing. The target is pinned
        // first because [_bindFreshPeer] dials whatever is pinned.
        AppLog.info('switch peerless -> bind fresh peer on new target');
        try {
          // The target is pinned first because [_bindFreshPeer] dials
          // whatever is pinned — unless this is a one-shot Auto move,
          // which passes the target directly so the state stays unpinned.
          if (pinTarget) {
            selectTarget(
              regionId: regionId,
              serverId: serverId,
              explicitTarget: explicitTarget,
            );
          }
          // [_startWith] only stops a previous tunnel when already
          // `connected`; the switch may have left one running while
          // `working`, so stop explicitly to never run two live tunnels
          // and so the bind POST travels over the direct network.
          if (!tunnelDown) {
            await _stopTunnel('switch');
            tunnelDown = true;
          }
          final fresh = await _bindFreshPeer(
            id,
            regionId: regionId,
            serverId: serverId,
          );
          await _startWith(fresh);
          return;
        } catch (e2) {
          AppLog.error('switch peerless bind failed', e2);
          _noteRateLimit(asVpnError(e2));
          // Fall through to the failure surfacing below.
        }
      }
      // On a clean failure the POST never bound the ephemeral key and the
      // old pair still matches the server-side peer.
      await _restoreKeypair(oldPriv: oldPriv, oldPub: oldPub, label: 'switch');
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
    final oldDial = snap.dial;
    final wasConnected = snap.phase == ConnPhase.connected;
    // Snapshot the working identity; read inside the `try` so a throwing
    // secure-storage read still releases the mutex (see _switchServerOp).
    String? oldPriv;
    String? oldPub;
    // True once a transport failure leaves the server-side outcome
    // uncertain (a timed-out POST may still have bound the key).
    var ambiguous = false;
    // See switchServer: a failure after the fallback stop leaves no tunnel
    // running and must surface `error`.
    var tunnelDown = false;
    try {
      oldPriv = await _device.privateKey();
      oldPub = await _device.publicKey();
      final id = await _device.deviceId();
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
            : () => snap = snap.copyWith(
                phase: ConnPhase.working,
                message: 'Retrying over direct connection…',
              ),
        onFallbackEnd: auto
            ? null
            : () => snap = snap.copyWith(
                phase: ConnPhase.working,
                message: 'Rotating…',
              ),
      );
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
      if (!tunnelDown) await _stopTunnel('rotate-restart');
      await _device.setKeypair(
        privateKey: kp.privateKey,
        publicKey: kp.publicKey,
      );
      await _startWith(dial);
      _pollsSinceRotate = 0;
      AppLog.info('rotate ok device=${AppLog.redact(id)} auto=$auto');
    } catch (e) {
      final vpnErr = asVpnError(e);
      AppLog.error(
        'rotate failed kind=${vpnErr?.kind ?? e.runtimeType} auto=$auto',
        vpnErr?.message ?? e,
      );
      _noteRateLimit(vpnErr);
      await _restoreKeypair(oldPriv: oldPriv, oldPub: oldPub, label: 'rotate');
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
      );
    } finally {
      release();
    }
  }
}
