/// Typed client for the privileged `boltmeshd` helper.
///
/// Speaks the newline-delimited JSON protocol defined in
/// `boltmeshd/internal/protocol/protocol.go`. The transport is
/// injectable so tests can script responses without a real socket.
///
/// The client validates every response strictly: the protocol version, the
/// echoed request id (correlation), the `ok`/`error`/`status` shape and the
/// full status schema. A response that violates any of these raises
/// [HelperException] rather than being silently defaulted. An optional `caps`
/// field advertises capabilities in both directions; the daemon's list is
/// exposed via [HelperClient.capabilities] and is advisory only.
library;

import 'dart:async';

import 'helper_socket.dart';
import 'helper_socket_stub.dart'
    if (dart.library.io) 'helper_socket_io.dart'
    as socket_platform;

class _MutationSlot {
  final Completer<void> done = Completer<void>();
  bool abandoned = false;

  void abandon() => abandoned = true;

  void release() {
    if (!done.isCompleted) done.complete();
  }
}

/// Wire-protocol version; must match the helper's `protocol.Version`.
const helperProtocolVersion = 1;

/// Capability tokens this client understands, mirroring the daemon's
/// `protocol.SupportedCapabilities`. Sent as an optional `caps` field; the
/// daemon's own list comes back on `ping` and is informational only — the
/// daemon enforces validation regardless, and absence is tolerated.
const helperCapabilities = <String>['strict-validation', 'caps'];

/// A helper-level failure (as opposed to a transport failure), carrying the
/// daemon's error code (`bad_config`, `unavailable`, …).
class HelperException implements Exception {
  HelperException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HelperException($code): $message';
}

/// The daemon's view of the tunnel. A zero/invalid handshake and zero
/// counters mean *unknown*, never *dead* on their own.
class HelperStatus {
  const HelperStatus({
    required this.interfaceName,
    required this.up,
    required this.stage,
    required this.endpoint,
    required this.publicKey,
    required this.lastHandshake,
    required this.rxBytes,
    required this.txBytes,
  });

  factory HelperStatus.fromJson(Map<String, dynamic> json) {
    final interfaceName = json['interface'];
    final up = json['up'];
    final stage = json['stage'];
    final lastHandshake = json['lastHandshake'];
    final rxBytes = json['rxBytes'];
    final txBytes = json['txBytes'];
    // Strict schema: a field that is missing or mistyped is a contract
    // violation, not "unknown". Silently defaulting here would let a
    // malformed daemon masquerade as a healthy one.
    if (interfaceName is! String ||
        up is! bool ||
        stage is! String ||
        lastHandshake is! num ||
        rxBytes is! num ||
        txBytes is! num) {
      throw HelperException('internal', 'helper status is malformed');
    }
    final endpoint = json['endpoint'] ?? '';
    final publicKey = json['publicKey'] ?? '';
    if (endpoint is! String || publicKey is! String) {
      throw HelperException('internal', 'helper status is malformed');
    }
    final epoch = lastHandshake.toInt();
    return HelperStatus(
      interfaceName: interfaceName,
      up: up,
      stage: stage,
      endpoint: endpoint,
      publicKey: publicKey,
      lastHandshake: epoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
          : null,
      rxBytes: rxBytes.toInt(),
      txBytes: txBytes.toInt(),
    );
  }

  final String interfaceName;
  final bool up;
  final String stage;
  final String endpoint;
  final String publicKey;
  final DateTime? lastHandshake;
  final int rxBytes;
  final int txBytes;
}

/// Client over [HelperSocket].
class HelperClient {
  HelperClient({HelperSocket? socket, this.callTimeout = defaultCallTimeout})
    : _socket = socket ?? socket_platform.createHelperSocket();

  final HelperSocket _socket;
  int _seq = 0;

  /// Capabilities the daemon advertised on the most recent `ping`. Empty
  /// until a ping succeeds; the daemon's list is advisory (see
  /// [helperCapabilities]).
  Set<String> _capabilities = const {};
  Set<String> get capabilities => _capabilities;

  /// Default backstop deadline for one helper round-trip. It is longer than
  /// the daemon's complete-operation budget so a normal helper response wins
  /// the race; the transport receives this same deadline and closes its
  /// connection when it expires. The per-call timeout still guarantees that
  /// an injected or future transport cannot leave a caller pending forever.
  static const defaultCallTimeout = Duration(seconds: 45);

  /// Per-instance override of [defaultCallTimeout] (tests use a short one).
  final Duration callTimeout;

  /// In-flight `status` exchange. The health tick reads stage, traffic and
  /// handshake concurrently, and on Linux each of those maps onto a separate
  /// `status` call — sharing one request collapses three socket round-trips
  /// per tick into one. Cleared as soon as it settles (success or failure),
  /// so the next tick and any `up`/`down` after it always read fresh daemon
  /// state.
  Future<HelperStatus>? _statusInFlight;
  Duration? _statusInFlightTimeout;

  /// Serializes lifecycle mutations. The tail follows the raw exchange, not
  /// just the public timeout wrapper, so a timed-out legacy transport can
  /// never overlap its retry with the operation it was meant to cancel.
  Future<void> _mutationTail = Future<void>.value();

  /// True when this platform has a helper to talk to.
  bool get isSupported => _socket.isSupported;

  /// Liveness + version check.
  Future<HelperStatus> ping({Duration? timeout}) =>
      _call('ping', timeout: timeout);

  /// Current tunnel status. Concurrent callers share one request.
  Future<HelperStatus> status({Duration? timeout}) {
    final effectiveTimeout = _effectiveTimeout(timeout);
    final inFlight = _statusInFlight;
    if (inFlight != null) {
      final inFlightTimeout = _statusInFlightTimeout;
      if (inFlightTimeout != null && effectiveTimeout < inFlightTimeout) {
        return _statusWithDeadline(inFlight, effectiveTimeout);
      }
      return inFlight;
    }
    final future = _call('status', timeout: timeout);
    _statusInFlight = future;
    _statusInFlightTimeout = effectiveTimeout;
    unawaited(
      future.then((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_statusInFlight, future)) {
          _statusInFlight = null;
          _statusInFlightTimeout = null;
        }
      }),
    );
    return future;
  }

  Future<HelperStatus> _statusWithDeadline(
    Future<HelperStatus> future,
    Duration timeout,
  ) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw HelperTransportException('helper status timed out');
    }
  }

  /// Validates and starts the tunnel with [wgQuickConfig].
  Future<HelperStatus> up(String wgQuickConfig, {Duration? timeout}) =>
      _enqueueMutation(
        _effectiveTimeout(timeout),
        (track) => _call(
          'up',
          config: wgQuickConfig,
          timeout: timeout,
          onExchange: track,
        ),
      );

  /// Idempotent teardown.
  Future<HelperStatus> down({Duration? timeout}) => _enqueueMutation(
    _effectiveTimeout(timeout),
    (track) => _call('down', timeout: timeout, onExchange: track),
  );

  Future<HelperStatus> _enqueueMutation(
    Duration queueTimeout,
    Future<HelperStatus> Function(void Function(Future<Map<String, dynamic>>))
    start,
  ) {
    final previous = _mutationTail;
    final slot = _MutationSlot();
    // Reserve the lane synchronously. Otherwise two calls made in the same
    // event-loop turn could both capture the old completed tail and overlap.
    _mutationTail = slot.done.future;
    final result = Completer<HelperStatus>();
    unawaited(result.future.then((_) {}, onError: (_) {}));
    unawaited(() async {
      var exchangeStarted = false;
      try {
        await previous.timeout(queueTimeout);
        if (slot.abandoned) {
          slot.release();
          return;
        }
        result.complete(
          await start((exchange) {
            exchangeStarted = true;
            // Keep the lane occupied until the transport itself settles. A
            // Future.timeout on a legacy exchange does not cancel its source.
            unawaited(
              exchange.then<void>(
                (_) => slot.release(),
                onError: (_, _) => slot.release(),
              ),
            );
          }),
        );
      } on TimeoutException {
        slot.abandon();
        if (!result.isCompleted) {
          result.completeError(
            HelperTransportException(
              'previous helper operation is still in progress',
            ),
          );
        }
        // Do not release the slot yet: a timed-out waiter must not let a
        // later mutation bypass the still-running raw exchange ahead of it.
        unawaited(
          previous.then<void>(
            (_) => slot.release(),
            onError: (_, _) => slot.release(),
          ),
        );
      } catch (e, st) {
        if (!result.isCompleted) result.completeError(e, st);
        if (!exchangeStarted) slot.release();
      }
    }());
    return result.future;
  }

  /// Uses the caller's requested budget without allowing a per-instance test
  /// or embedding override to make a shipped operation live longer than its
  /// adapter budget.
  Duration _effectiveTimeout(Duration? requested) {
    if (requested == null) return callTimeout;
    return callTimeout.compareTo(requested) < 0 ? callTimeout : requested;
  }

  Future<HelperStatus> _call(
    String op, {
    String? config,
    Duration? timeout,
    void Function(Future<Map<String, dynamic>>)? onExchange,
  }) async {
    final requestId = '${++_seq}';
    final effectiveTimeout = _effectiveTimeout(timeout);
    final request = <String, dynamic>{
      'v': helperProtocolVersion,
      'id': requestId,
      'caps': helperCapabilities,
      'op': op,
      'config': ?config,
    };
    final Map<String, dynamic> response;
    try {
      final Future<Map<String, dynamic>> exchange;
      final timedSocket = _socket;
      if (timedSocket is HelperSocketWithTimeout) {
        // The production transports close the socket/native pipe themselves
        // when this deadline expires. That close is the cancellation signal
        // observed by boltmeshd; Future.timeout alone would leave the request
        // running on the daemon after the UI had already given up.
        exchange = timedSocket.exchangeWithTimeout(
          request,
          timeout: effectiveTimeout,
        );
      } else {
        // Keep injected/legacy transports source-compatible. They still get a
        // caller-side backstop, but cannot provide transport cancellation.
        exchange = timedSocket.exchange(request);
      }
      onExchange?.call(exchange);
      response = await exchange.timeout(effectiveTimeout);
    } on TimeoutException {
      // A wedged daemon must surface as a transport failure (null/unknown to
      // the health tick), never as a future that stays pending forever.
      throw HelperTransportException('helper $op timed out');
    }

    // Strict response checks, in order: version, correlation, then the
    // ok/error/status shape. A response that fails any of these is a
    // protocol contract violation from the daemon.
    if (response['v'] is! int || response['v'] != helperProtocolVersion) {
      throw HelperException(
        'bad_request',
        'unsupported helper protocol version: ${response['v']}',
      );
    }
    if (response['id'] != requestId) {
      throw HelperException(
        'internal',
        'helper response id mismatch: got ${response['id']}, '
            'want $requestId',
      );
    }
    final ok = response['ok'];
    if (ok is! bool) {
      throw HelperException('internal', 'helper response is missing ok');
    }

    if (!ok) {
      final error = response['error'];
      if (error is! Map) {
        throw HelperException('internal', 'helper error is missing');
      }
      final code = error['code'];
      final message = error['message'];
      if (code is! String || message is! String) {
        throw HelperException('internal', 'helper error is malformed');
      }
      if (response.containsKey('status')) {
        throw HelperException('internal', 'helper error carries a status');
      }
      throw HelperException(code, message);
    }

    if (response.containsKey('error')) {
      throw HelperException('internal', 'helper success carries an error');
    }
    final status = response['status'];
    if (status is! Map) {
      throw HelperException('internal', 'helper response is missing status');
    }
    _recordCapabilities(response['caps']);
    return HelperStatus.fromJson(Map<String, dynamic>.from(status));
  }

  /// Records the daemon's advertised capabilities from a `ping` response.
  /// Absence is fine: negotiation is optional and the daemon enforces
  /// validation regardless. Tokens are bounded the same way the daemon
  /// bounds them, so a malformed list cannot smuggle data through.
  void _recordCapabilities(Object? caps) {
    if (caps == null) return;
    if (caps is! List) {
      throw HelperException('internal', 'helper caps are malformed');
    }
    const maxCaps = 16;
    const maxCapLength = 32;
    final token = RegExp(r'^[a-z0-9-]+$');
    final parsed = <String>{};
    if (caps.length > maxCaps) {
      throw HelperException('internal', 'helper caps are malformed');
    }
    for (final cap in caps) {
      if (cap is! String ||
          cap.isEmpty ||
          cap.length > maxCapLength ||
          !token.hasMatch(cap)) {
        throw HelperException('internal', 'helper caps are malformed');
      }
      parsed.add(cap);
    }
    _capabilities = parsed;
  }
}
