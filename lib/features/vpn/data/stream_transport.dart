// The stream transport one tunnel start runs on.
//
// [StreamTransport] is what the control plane sends (a credential set); this is
// what this particular start needs: the credential set plus the two loopback
// addresses the helper's bridge moves datagrams between. The peer endpoint in
// the tunnel config is rewritten to [listen], and [deliver] is the local
// WireGuard listen port the bridge hands the node's datagrams back to.
//
// Both addresses are allocated per start rather than fixed, because they have
// to be free on this machine: the bridge binds [listen], and the kernel binds
// [deliver] for the interface's own ListenPort.
library;

import 'dart:io';

import 'models.dart';

/// A resolved stream transport: where the tunnel points, where datagrams go
/// back, and the credentials the bridge presents.
class TunnelTransport {
  const TunnelTransport({
    required this.listen,
    required this.deliver,
    required this.credential,
  });

  /// `127.0.0.1:<port>` the tunnel's peer `Endpoint` points at.
  final String listen;

  /// `127.0.0.1:<port>` of the local WireGuard listen port, where the node's
  /// datagrams are delivered. Must equal the conf's `ListenPort`.
  final String deliver;

  /// The node credential the bridge authenticates with.
  final StreamTransport credential;

  /// The loopback host both addresses use. Fixed, not configurable: the helper
  /// validates it, and a non-loopback address would make the privileged daemon
  /// relay datagrams for a peer it should be routing around.
  static const loopbackHost = '127.0.0.1';

  /// Port of [listen], which becomes the peer endpoint in the conf.
  int get listenPort => _portOf(listen);

  /// Port of [deliver], which becomes the interface's `ListenPort`.
  int get deliverPort => _portOf(deliver);

  static int _portOf(String address) {
    final index = address.lastIndexOf(':');
    if (index < 0) {
      throw ArgumentError('Not a host:port address: $address');
    }
    final port = int.tryParse(address.substring(index + 1));
    if (port == null || port <= 0 || port > 65535) {
      throw ArgumentError('Bad port in address: $address');
    }
    return port;
  }

  /// The `transport` object for the helper's `up` request.
  ///
  /// Field names and value encodings match `protocol.TransportSpec` exactly:
  /// the credential passes through as the control plane sent it, and only the
  /// two loopback addresses are this client's contribution.
  Map<String, Object?> toSpecJson() => {
    'mode': 'stream',
    'listen': listen,
    'deliver': deliver,
    'server': credential.server,
    'server_name': credential.serverName,
    'spki_sha256': credential.spkiPins,
    'psk': credential.psk,
    'client_id': credential.clientId,
  };

  @override
  String toString() =>
      'TunnelTransport($listen -> $deliver via ${credential.serverName})';
}

/// Two free loopback UDP ports for [TunnelTransport].
///
/// Both sockets are opened and closed again purely to ask the kernel which
/// ports are free, so there is an unavoidable window between closing them and
/// the helper (or `wg-quick`) binding them. That window is narrow, the ports
/// are loopback-only, and the consequence is bounded: the daemon refuses a taken
/// port with `bad_config` before it brings the tunnel up, which the ladder
/// already handles. Reserving the sockets instead is not an option — the
/// binding happens in another process, seconds later, in a different privilege
/// domain.
Future<({int listen, int deliver})> allocateLoopbackPorts() async {
  final listen = await _freeUdpPort();
  // Deliberately a second probe rather than listen +/- 1: the two sockets are
  // separate binds, and a neighbouring port is no more likely to be free than
  // any other.
  var deliver = await _freeUdpPort();
  for (var attempt = 0; deliver == listen && attempt < 16; attempt++) {
    deliver = await _freeUdpPort();
  }
  if (deliver == listen) {
    throw StateError('Could not find two distinct loopback UDP ports.');
  }
  return (listen: listen, deliver: deliver);
}

Future<int> _freeUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    return socket.port;
  } finally {
    // Fire and forget: the port is already known, and the close only has to
    // happen before the next bind. `close()` is void on this SDK, so there is
    // nothing to await.
    socket.close();
  }
}
