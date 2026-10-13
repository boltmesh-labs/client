part of 'connection_controller.dart';

extension ConnectionSwitch on ConnectionController {
  /// Move the tunnel to a named target — a server pick from the Regions tab or
  /// an Auto re-pick.
  ///
  /// This is just `connect` with an explicit target: the backend moves the
  /// binding (or binds/replays as needed), so this client no longer has a
  /// separate server-side "switch" call and never reasons about where its
  /// binding is. The
  /// key we already hold is moved, which preserves the overlay IP and byte
  /// counters; a device that somehow holds no key binds a fresh one.
  Future<void> _switchServerOp({
    required String? regionId,
    required String? serverId,
    // False for one-shot Auto moves: the picked target is dialed without
    // pinning, so the state stays unpinned and later connects re-pick. A
    // pinned target is always the explicit one — no caller pins a target it
    // considers automatic — so this single flag also carries the explicit bit
    // written by [selectTarget].
    bool pinTarget = true,
    // Quick Connect's snapshot of [_teardownEpoch]: a Disconnect that landed
    // during its lock-free discovery must win over this queued switch.
    int? expectedTeardown,
  }) async {
    // Clear any previous failure signal first: only an actual failure below
    // sets it again, so the benign same-target no-op never snacks.
    snap = snap.copyWith(opFailed: false);
    // Skip only against a target the tunnel is actually on. A pin outlives
    // the target it names — it is restored from storage on every cold start —
    // so a restored pin can name a server the live dial is not on, and
    // skipping there would swallow a real tap while reporting "already
    // connected" for a tunnel that is somewhere else. A server request
    // therefore compares against the live dial, and only while one is up.
    final live = snap.phase == ConnPhase.connected ? snap.dial?.serverId : null;
    final sameServer = serverId != null && serverId == live;
    if (sameServer) {
      AppLog.info('switch skipped: already on $serverId');
      // No tunnel work needed, but an explicit tap still carries pin intent:
      // Auto (unpinned) tapping the live server must land pinned so the
      // Regions tab highlights it. One-shot Auto moves (pinTarget false)
      // stay unpinned.
      if (pinTarget) {
        selectTarget(serverId: serverId, explicitTarget: pinTarget);
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
    // True once a transport failure leaves the server-side outcome uncertain
    // (a timed-out POST may still have moved the binding). Declared outside `try`
    // so the `catch` recovery can read it.
    var ambiguous = false;
    // True once the fallback path stopped the tunnel: the UI must not claim to
    // still be connected on the old server when no tunnel runs.
    var tunnelDown = false;
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
        if (pinTarget) {
          selectTarget(serverId: serverId, explicitTarget: pinTarget);
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
            selectTarget(serverId: dial.serverId, explicitTarget: pinTarget);
          }
        }
        return;
      }
      snap = snap.copyWith(
        phase: ConnPhase.working,
        message: 'Switching…',
        recoveryAction: null,
        recoveryReason: null,
        recoveryDetail: null,
      );
      final deviceId = id;
      // Move the key we hold; a device with no key binds a fresh one.
      final publicKey = await _device.publicKey();
      if (sessionEpoch != _sessionEpoch) return;
      final DialParams dial;
      if (publicKey == null) {
        if (pinTarget) {
          selectTarget(serverId: serverId, explicitTarget: pinTarget);
        }
        dial = await _bindFreshKey(
          deviceId,
          regionId: regionId,
          serverId: serverId,
          sessionEpoch: sessionEpoch,
        );
        if (sessionEpoch != _sessionEpoch) return;
        if (!tunnelDown) {
          await _stopTunnel('switch-restart');
          if (sessionEpoch != _sessionEpoch) return;
          tunnelDown = true;
        }
      } else {
        // Probe through the live tunnel first (loopback APIs bypass it without
        // stopping). The tunnel is stopped only when the backend is
        // unreachable through the current path.
        final result = await _postViaTunnelOrDirect(
          post: ({Duration? timeout}) => _connectPost(
            deviceId,
            publicKey,
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
        final bound = result.dial;
        if (bound == null) {
          // Every attempt failed with a transport error: keep the old tunnel
          // up and report, instead of stranding the user with nothing running.
          ambiguous = true;
          throw _ambiguousFailure(
            '/vpn-devices/$deviceId/connect',
            'Switch request failed. Check your connection and retry.',
          );
        }
        dial = bound;
        // The tunnel may still be up (in-tunnel success): never run two live
        // tunnels (Windows/Wintun route wedge). Skipped when the fallback path
        // already stopped it.
        if (!tunnelDown) {
          await _stopTunnel('switch-restart');
          if (sessionEpoch != _sessionEpoch) return;
          tunnelDown = true;
        }
      }
      await _startWith(dial, sessionEpoch: sessionEpoch);
      if (sessionEpoch != _sessionEpoch) return;
      // Record the exact bound server so the Regions tab highlights it and
      // reconnects keep it (a region-targeted pick pins the server the backend
      // chose). One-shot Auto moves skip this so the state stays unpinned.
      if (pinTarget) {
        selectTarget(
          serverId: serverId ?? dial.serverId,
          explicitTarget: pinTarget,
        );
      }
    } catch (e) {
      if (sessionEpoch != _sessionEpoch) return;
      final vpnErr = asVpnError(e);
      AppLog.error(
        'switch failed kind=${vpnErr?.kind ?? e.runtimeType}',
        vpnErr?.message ?? e,
      );
      // A double transport failure leaves the server-side outcome uncertain,
      // so say so: a Connect re-binds the stored key. The fallback path
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

  /// Rotate the WireGuard key in place: same server and overlay IP, the binding
  /// moves to a fresh key and the tunnel restarts on the new dial.
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
    // True once the connect POST returned: the server holds the fresh key, so a
    // later failure must keep it instead of restoring the old pair.
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
          recoveryAction: null,
          recoveryReason: null,
          recoveryDetail: null,
        );
      }
      final kp = await _keys.generate();
      if (sessionEpoch != _sessionEpoch) return;
      final deviceId = id;
      // Probe through the live tunnel first; stop only when the backend is
      // unreachable through the current path (same rule as switch). No target
      // is named, so the backend rotates the binding in place on its server.
      final result = await _postViaTunnelOrDirect(
        post: ({Duration? timeout}) =>
            _connectPost(deviceId, kp.publicKey, null, null, timeout: timeout),
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
          '/vpn-devices/$deviceId/connect',
          'Rotate request failed. Check your connection and retry.',
        );
      }
      // The POST was accepted: the server now holds the fresh
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
