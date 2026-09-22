/// Typed client for the privileged `boltmeshd` helper.
///
/// Speaks the newline-delimited JSON protocol defined in
/// `boltmeshd/internal/protocol/protocol.go`. The transport is
/// injectable so tests can script responses without a real socket.
library;

import 'dart:async';

import 'helper_socket.dart';
import 'helper_socket_stub.dart'
    if (dart.library.io) 'helper_socket_io.dart'
    as socket_platform;

/// Wire-protocol version; must match the helper's `protocol.Version`.
const helperProtocolVersion = 1;

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
    final epoch = (json['lastHandshake'] as num?)?.toInt() ?? 0;
    return HelperStatus(
      interfaceName: json['interface'] as String? ?? '',
      up: json['up'] == true,
      stage: json['stage'] as String? ?? 'disconnected',
      endpoint: json['endpoint'] as String? ?? '',
      publicKey: json['publicKey'] as String? ?? '',
      lastHandshake: epoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
          : null,
      rxBytes: (json['rxBytes'] as num?)?.toInt() ?? 0,
      txBytes: (json['txBytes'] as num?)?.toInt() ?? 0,
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

  /// Default backstop deadline for one helper round-trip. The socket
  /// transport has its own read deadline (see `helper_socket_io.dart`), but
  /// an injected or future transport could ignore it: the per-call timeout
  /// guarantees the returned future always settles, so one wedged daemon can
  /// never leave [_statusInFlight] pending forever and poison every later
  /// read.
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

  /// True when this platform has a helper to talk to.
  bool get isSupported => _socket.isSupported;

  /// Liveness + version check.
  Future<HelperStatus> ping() => _call('ping');

  /// Current tunnel status. Concurrent callers share one request.
  Future<HelperStatus> status() {
    final inFlight = _statusInFlight;
    if (inFlight != null) return inFlight;
    final future = _call('status');
    _statusInFlight = future;
    unawaited(
      future.then((_) {}, onError: (_) {}).whenComplete(() {
        _statusInFlight = null;
      }),
    );
    return future;
  }

  /// Validates and starts the tunnel with [wgQuickConfig].
  Future<HelperStatus> up(String wgQuickConfig) =>
      _call('up', config: wgQuickConfig);

  /// Idempotent teardown.
  Future<HelperStatus> down() => _call('down');

  Future<HelperStatus> _call(String op, {String? config}) async {
    final Map<String, dynamic> response;
    try {
      response = await _socket
          .exchange({
            'v': helperProtocolVersion,
            'id': '${++_seq}',
            'op': op,
            'config': ?config,
          })
          .timeout(callTimeout);
    } on TimeoutException {
      // A wedged daemon must surface as a transport failure (null/unknown to
      // the health tick), never as a future that stays pending forever.
      throw HelperTransportException('helper $op timed out');
    }

    if (response['v'] != helperProtocolVersion) {
      throw HelperException(
        'bad_request',
        'unsupported helper protocol version: ${response['v']}',
      );
    }
    if (response['ok'] != true) {
      final error = response['error'];
      final code = error is Map ? error['code'] as String? : null;
      final message = error is Map ? error['message'] as String? : null;
      throw HelperException(code ?? 'internal', message ?? 'helper error');
    }
    final status = response['status'];
    if (status is! Map) {
      throw HelperException('internal', 'helper response is missing status');
    }
    return HelperStatus.fromJson(Map<String, dynamic>.from(status));
  }
}
