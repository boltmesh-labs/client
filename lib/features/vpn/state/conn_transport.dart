part of 'connection_controller.dart';

extension ConnectionTransport on ConnectionController {
  /// Runs one control-plane attempt with an optional extra [timeout]
  /// (null = Dio's own budgets, i.e. the raw-network attempt). Returns the
  /// result, or null on a pure transport failure — timeout, unreachable,
  /// TLS/cert rejection — so the caller can retry over another path.
  /// App-level rejections rethrow: they prove the backend reachable, so the
  /// tunnel must never be stopped for them.
  ///
  /// The timeout aborts the in-flight request via [CancelToken] (rather than
  /// leaving it running): a timed-out attempt must not later land and bind a
  /// key the store has already moved past (see [_bindFreshPeer]).
  Future<T?> _attempt<T>(
    String label,
    Future<T> Function(CancelToken cancel) call, {
    Duration? timeout,
  }) async {
    final cancel = CancelToken();
    try {
      final future = call(cancel);
      if (timeout == null) return await future;
      return await future.timeout(
        timeout,
        onTimeout: () {
          cancel.cancel('$label timed out');
          throw TimeoutException('$label timed out', timeout);
        },
      );
    } on TimeoutException catch (e) {
      AppLog.error('$label timed out', e);
      return null;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel || isTransportFailure(e)) {
        AppLog.error('$label network-failed', e);
        return null;
      }
      rethrow;
    }
  }

  /// Single switch POST (see [_attempt]).
  Future<DialParams?> _switchPost(
    String id,
    String publicKey,
    String? regionId,
    String? serverId, {
    Duration? timeout,
  }) => _attempt(
    'switch POST',
    (cancel) => _api.switchServer(
      deviceId: id,
      publicKey: publicKey,
      regionId: regionId,
      serverId: serverId,
      cancelToken: cancel,
    ),
    timeout: timeout,
  );

  /// Single rotate-keys POST (see [_attempt]).
  Future<DialParams?> _rotatePost(
    String id,
    String publicKey, {
    Duration? timeout,
  }) => _attempt(
    'rotate POST',
    (cancel) => _api.rotateKeys(
      deviceId: id,
      publicKey: publicKey,
      cancelToken: cancel,
    ),
    timeout: timeout,
  );

  /// Through-tunnel probe first: when a tunnel is up, the control-plane
  /// call is attempted before any stop. Loopback APIs never travel inside
  /// the tunnel (split-tunnel keeps them direct), so the probe goes out
  /// without a short timeout there — but still without stopping first. The
  /// tunnel is stopped only when the probe fails with a transport error
  /// (backend unreachable through the current path); app-level errors never
  /// stop the tunnel.
  bool _tryThroughTunnelFirst(bool wasConnected) {
    if (debugForceThroughTunnel != null) return debugForceThroughTunnel!;
    return wasConnected && _tunnel.isReady;
  }

  /// Timeout for the through-tunnel probe. Loopback APIs bypass the tunnel,
  /// so no short budget is needed there; the direct call keeps Dio's own
  /// timeouts.
  Duration? _probeTimeout() =>
      Env.isLoopbackApi ? null : ConnectionTuning.throughTunnelAttempt;

  /// True when the backend still looks reachable from cached poll state
  /// (no transport failure and a recent successful poll). Used to suppress
  /// a tunnel stop that a racing poll success has made unnecessary.
  bool _backendLooksReachable() => !isBackendCorroborated(
    pollFailures: snap.pollFailures,
    lastStatusAt: snap.lastStatusAt,
    now: _clock.now(),
  );

  /// In-tunnel probe: [call] with [timeout] (defaulting to the shared
  /// [_probeTimeout]), null only on transport failure. Recovery callers pass
  /// [ConnectionTuning.recoveryProbeTimeout] so an already-suspect path is
  /// abandoned sooner. App-level errors rethrow so the caller can keep the
  /// tunnel up.
  Future<T?> _probeThroughTunnel<T>(
    Future<T> Function(CancelToken cancel) call,
    String label, {
    Duration? timeout,
  }) => _attempt('$label probe', call, timeout: timeout ?? _probeTimeout());

  /// Shared switch/rotate ladder: probe through the live tunnel first, then
  /// over the raw network, stopping the tunnel only when the backend is
  /// unreachable through the current path (a transport failure). The tunnel
  /// is never stopped for an app-level rejection.
  ///
  /// Returns the bound dial (null when every attempt failed at transport
  /// level), whether a stop happened — so the caller stops exactly once —
  /// and whether the in-tunnel probe failed, which leaves the server-side
  /// outcome unknown (see [_surfaceOpFailure]).
  ///
  /// [onFallbackStart]/[onFallbackEnd] bracket the fallback stop with the
  /// caller's user-facing progress messages; a null callback is a no-op
  /// (background rotations stay silent).
  Future<({DialParams? dial, bool tunnelDown, bool probeTransportFailure})>
  _postViaTunnelOrDirect({
    required Future<DialParams?> Function({Duration? timeout}) post,
    required bool wasConnected,
    required String stopLabel,
    bool initiallyDown = false,
    void Function()? onFallbackStart,
    void Function()? onFallbackEnd,
    Duration? probeTimeout,
  }) async {
    var tunnelDown = initiallyDown;
    Future<void> stopAfterProbe({required bool reportRetry}) async {
      if (reportRetry) onFallbackStart?.call();
      await _stopTunnel(stopLabel);
      tunnelDown = true;
      onFallbackEnd?.call();
    }

    DialParams? dial;
    // Only the in-tunnel probe records this: it means the POST may or may
    // not have reached the server before the path died.
    var probeTransportFailure = false;
    if (_tryThroughTunnelFirst(wasConnected)) {
      AppLog.info('$stopLabel attempt in-tunnel');
      dial = await post(timeout: probeTimeout ?? _probeTimeout());
      probeTransportFailure = dial == null;
      if (dial == null) {
        AppLog.info('$stopLabel falling back to direct network');
        await stopAfterProbe(reportRetry: true);
      }
    } else if (wasConnected) {
      // No probed tunnel (not ready), but the old tunnel may still be up:
      // try the POST first and stop only when the backend is unreachable
      // through the current path.
      AppLog.info('$stopLabel attempt direct');
      dial = await post();
      if (dial == null) {
        AppLog.info('$stopLabel direct unreachable, retrying after stop');
        await stopAfterProbe(reportRetry: false);
      }
    }
    if (dial == null && !tunnelDown && !wasConnected) {
      // Idle/error with no tunnel running: plain direct attempt.
      dial = await post();
    }
    if (dial == null && tunnelDown) {
      // Same ephemeral key: reconciles a late attempt-1 success instead
      // of orphaning it with a second key.
      dial = await post();
    }
    return (
      dial: dial,
      tunnelDown: tunnelDown,
      probeTransportFailure: probeTransportFailure,
    );
  }

  /// Synthetic transport-shaped failure for "no attempt resolved", so the
  /// shared catch surfaces the ambiguous banner (see [_surfaceOpFailure])
  /// instead of a message that claims the old target is still live. Carries
  /// a user-facing [ApiException] exactly like a real Dio transport error.
  DioException _ambiguousFailure(String path, String message) => DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.receiveTimeout,
    error: ApiException(ApiErrorKind.network, message),
  );

  /// Restores the pre-op keypair after a clean failure: the POST never bound
  /// the ephemeral key, so the old pair still matches the server-side peer.
  /// Re-checked first, because something may have rotated the store
  /// mid-flight and a retry must reuse the working identity. Best-effort: the
  /// caller's message still reports the failure. (After a double transport
  /// failure the server may hold the new key; Connect reconciles via config.)
  Future<void> _restoreKeypair({
    required String? oldPriv,
    required String? oldPub,
    required String label,
  }) async {
    if (oldPriv == null || oldPub == null) return;
    try {
      final current = await _device.privateKey();
      if (current != oldPriv) {
        AppLog.info('$label restoring previous keypair');
        await _device.setKeypair(privateKey: oldPriv, publicKey: oldPub);
      }
    } catch (e) {
      AppLog.error('$label keypair restore failed', e);
    }
  }

  /// Shared switch/rotate failure surfacing. A failure after the fallback
  /// stop leaves no tunnel running, so it must surface `error` (ticks stopped,
  /// stale stage dropped) instead of claiming to still be connected on the
  /// old server. Otherwise a previously live session is kept and annotated.
  /// A Connect reconciles via config/connect.
  void _surfaceOpFailure({
    required Object e,
    required ApiException? vpnErr,
    required bool ambiguous,
    required bool tunnelDown,
    required bool wasConnected,
    required DialParams? oldDial,
    required String ambiguousPrefix,
    required String cleanPrefix,
  }) {
    final wait = _noteRateLimit(vpnErr);
    final reason = wait != null
        ? _rateLimitMessage(wait)
        : (vpnErr?.message ?? e.toString());
    final prefix = ambiguous ? ambiguousPrefix : cleanPrefix;
    if (tunnelDown) {
      // No tunnel is running and no reconnect is scheduled: stop the ticks
      // (they early-return while not connected, but must not linger behind
      // an error) and drop the stale stage.
      _stopPolling();
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: 'Tunnel stopped. $prefix $reason Tap Connect to reconcile.',
        lastStage: null,
        opFailed: true,
      );
      if (oldDial != null) {
        snap = snap.copyWith(dial: oldDial);
      }
    } else if (wasConnected && oldDial != null) {
      snap = snap.copyWith(
        phase: ConnPhase.connected,
        dial: oldDial,
        message: '$prefix $reason',
        opFailed: true,
      );
    } else {
      snap = snap.copyWith(
        phase: ConnPhase.error,
        message: reason,
        opFailed: true,
      );
      if (oldDial != null) {
        snap = snap.copyWith(dial: oldDial);
      }
    }
  }
}
