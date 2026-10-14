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
import 'stream_transport.dart';

/// Wire-protocol version; must match the helper's `protocol.Version`.
const helperProtocolVersion = 1;

/// Capability tokens this client understands, mirroring the daemon's
/// `protocol.SupportedCapabilities`. Sent as an optional `caps` field; the
/// daemon's own list comes back on `ping` and is informational only — the
/// daemon enforces validation regardless, and absence is tolerated.
const helperCapabilities = <String>['strict-validation', 'caps'];

/// The token the daemon advertises when its build can run a stream transport.
/// Matched against [HelperClient.capabilities] from `ping` before the stream
/// rung is ever selected.
const capStreamTransport = 'stream-transport';

/// Tunnel stages the helper protocol permits, mirroring the daemon's
/// `protocol.Stage*` constants. Any other value is a contract violation (an
/// incompatible or malformed daemon), not an unknown state to be defaulted:
/// mapping a mystery stage by the `up` flag could report a dead tunnel as
/// connected and suppress death detection.
const helperStages = <String>{'connected', 'connecting', 'disconnected'};

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
    required this.up,
    required this.stage,
    required this.endpoint,
    required this.publicKey,
    required this.lastHandshake,
    required this.rxBytes,
    required this.txBytes,
    this.streamSession,
  });

  factory HelperStatus.fromJson(Map<String, dynamic> json) {
    final interfaceName = json['interface'];
    final up = json['up'];
    final stage = json['stage'];
    final lastHandshake = json['lastHandshake'];
    final rxBytes = json['rxBytes'];
    final txBytes = json['txBytes'];
    final streamSession = json['streamSession'];
    // Strict schema: a field that is missing or mistyped is a contract
    // violation, not "unknown". Silently defaulting here would let a
    // malformed daemon masquerade as a healthy one. `streamSession` is
    // the one optional field: absent means no stream transport is live
    // (or a daemon that predates the field), which is a valid state, not
    // a violation — but a present value that is not a bool is.
    if (interfaceName is! String ||
        up is! bool ||
        stage is! String ||
        !helperStages.contains(stage) ||
        lastHandshake is! num ||
        rxBytes is! num ||
        txBytes is! num ||
        (streamSession != null && streamSession is! bool)) {
      throw HelperException('internal', 'helper status is malformed');
    }
    final endpoint = json['endpoint'] ?? '';
    final publicKey = json['publicKey'] ?? '';
    if (endpoint is! String || publicKey is! String) {
      throw HelperException('internal', 'helper status is malformed');
    }
    final epoch = lastHandshake.toInt();
    return HelperStatus(
      up: up,
      stage: stage,
      endpoint: endpoint,
      publicKey: publicKey,
      lastHandshake: epoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
          : null,
      rxBytes: rxBytes.toInt(),
      txBytes: txBytes.toInt(),
      streamSession: streamSession as bool?,
    );
  }

  final bool up;
  final String stage;
  final String endpoint;
  final String publicKey;
  final DateTime? lastHandshake;
  final int rxBytes;
  final int txBytes;

  /// The stream transport's TLS session state, or null when no stream
  /// transport is live (native/awg rung, or a daemon that predates the
  /// field). Non-null distinguishes "session establishing" (false) from
  /// "session established" (true); see [HelperTunnelAdapter.readStreamSession].
  final bool? streamSession;
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

  /// Default backstop deadline for one helper round-trip. The transport
  /// receives this same deadline and closes its connection when it expires.
  /// The per-call timeout still guarantees that an injected or future transport
  /// cannot leave a caller pending forever.
  static const defaultCallTimeout = Duration(seconds: 10);

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

  /// True when this platform has a helper to talk to.
  bool get isSupported => _socket.isSupported;

  /// Liveness + version check.
  Future<HelperStatus> ping({Duration? timeout}) =>
      _call('ping', timeout: timeout);

  /// Current tunnel status. Concurrent callers share one request.
  ///
  /// A shared request is bounded by the first caller's deadline: a later
  /// caller may only shorten its own wait (it gets an independent deadline
  /// wrapper while the shared exchange keeps running for the others), never
  /// extend it. Extending is not possible anyway — the transport already
  /// received the original deadline and cancels the exchange when it expires —
  /// so a caller that needs more time must wait for this request to settle and
  /// issue a fresh one.
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
  ///
  /// Lifecycle mutations are not serialized here: the daemon's FIFO operation
  /// gate orders `up`/`down` and cancels a queued or running one when this
  /// client drops its connection at its deadline (see the transports'
  /// cancellation paths). The caller-side deadline still bounds the wait.
  Future<HelperStatus> up(
    String wgQuickConfig, {
    TunnelTransport? transport,
    Duration? timeout,
  }) => _call(
    'up',
    config: wgQuickConfig,
    transport: transport?.toSpecJson(),
    timeout: timeout,
  );

  /// Idempotent teardown. See [up] on serialization.
  Future<HelperStatus> down({Duration? timeout}) =>
      _call('down', timeout: timeout);

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
    Map<String, Object?>? transport,
    Duration? timeout,
  }) async {
    final requestId = '${++_seq}';
    final effectiveTimeout = _effectiveTimeout(timeout);
    final request = <String, dynamic>{
      'v': helperProtocolVersion,
      'id': requestId,
      'caps': helperCapabilities,
      'op': op,
      'config': ?config,
      // Only ever set on `up`, and the daemon rejects it on every other
      // operation — so it is omitted rather than sent as null.
      'transport': ?transport,
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
