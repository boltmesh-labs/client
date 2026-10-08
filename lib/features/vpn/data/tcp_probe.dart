import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tcp_probe_stub.dart'
    if (dart.library.io) 'tcp_probe_io.dart'
    as probe_io;

/// Pre-demote reachability probe for the stream rung's TLS port.
///
/// The stream rung carries the tunnel's datagrams inside a TCP/TLS session
/// to the node, so a demotion onto it can only succeed while that port
/// answers. When the port is unreachable (node down, network filtering it)
/// the restart is skipped and the ladder moves servers instead of spending
/// the heal on a known-dead endpoint. Tri-state like the other probes:
/// true = reachable, false = unreachable, null = unknown (unsupported
/// platform, unparseable target, probe errored) — unknown fails open onto
/// the demote, which is absence of evidence, never proof of death.
abstract class TcpProbe {
  /// TCP connect to [host]:[port]. Never throws (see [probe_io.tcpConnect]).
  Future<bool?> check(String host, int port, {Duration timeout});
}

/// A TCP connect function: completes when [host]:[port] answers.
typedef TcpConnect = Future<bool?> Function(
  String host,
  int port,
  Duration timeout,
);

/// Injectable TCP probe (native platforms via `dart:io`).
class SocketTcpProbe implements TcpProbe {
  SocketTcpProbe({TcpConnect? connect})
    : _connect = connect ?? probe_io.tcpConnect;

  final TcpConnect _connect;

  @override
  Future<bool?> check(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (host.trim().isEmpty || port <= 0 || port > 65535) return null;
    try {
      return await _connect(host, port, timeout);
    } catch (_) {
      return null;
    }
  }
}

final tcpProbeProvider = Provider<TcpProbe>((_) => SocketTcpProbe());

/// The host and port halves of a stream `server` value (`host[:port]`), or
/// null when it names nothing dialable. A bare host takes [defaultPort]
/// (443, the only port a stream dials); a bracketed `[v6]:port` is the only
/// unambiguous v6 form, and a bare v6 literal keeps the default port. Pure
/// so it can be unit-tested.
(String, int)? parseTcpHostPort(String server, {int defaultPort = 443}) {
  if (defaultPort <= 0 || defaultPort > 65535) return null;
  final v = server.trim();
  if (v.isEmpty) return null;
  final bracketed = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(v);
  if (bracketed != null) {
    return _halves(bracketed.group(1)!, bracketed.group(2)!);
  }
  final plain = RegExp(r'^([^:]+):(\d+)$').firstMatch(v);
  if (plain != null) {
    return _halves(plain.group(1)!, plain.group(2)!);
  }
  if (!v.contains(':')) {
    // A bare hostname or IP literal: resolution happens at connect time, so
    // only emptiness (rejected above) and whitespace are rejected here.
    if (v.contains(' ')) return null;
    return (v, defaultPort);
  }
  // A single colon that is not `host:digits` is malformed (e.g. a bad port).
  // Several colons is a bare IPv6 literal, which keeps the default port —
  // connect-time resolution decides whether it dials.
  if (':'.allMatches(v).length == 1) return null;
  return (v, defaultPort);
}

(String, int)? _halves(String host, String port) {
  final h = host.trim();
  final p = int.tryParse(port);
  if (h.isEmpty || h.contains(' ') || p == null || p <= 0 || p > 65535) {
    return null;
  }
  return (h, p);
}
