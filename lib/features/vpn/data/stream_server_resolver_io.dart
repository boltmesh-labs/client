/// Resolves the stream node's host to a literal address for the native bridge.
///
/// The bridge must be handed a literal address, not a hostname. Once the tunnel
/// is up this app's resolver follows the tunnel, so resolving the node's own
/// hostname would go *through* the tunnel that the node's stream is needed to
/// bring up — a deadlock. Resolving here, before the native start and before
/// the TUN exists, keeps the query on the physical network and out of the
/// bridge's start path.
library;

import 'dart:async';
import 'dart:io';

import 'tunnel_tuning.dart';

/// Returns `host:port` with the host replaced by a resolved address: IPv4 when
/// one exists, otherwise the first IPv6 answer (bracketed). A [server] whose
/// host is already a literal address is returned unchanged.
///
/// [lookup] and [timeout] exist for tests; production passes neither.
Future<String> resolveStreamServer(
  String server, {
  Future<List<InternetAddress>> Function(String host)? lookup,
  Duration timeout = TunnelTuning.streamResolveTimeout,
}) async {
  final uri = Uri.parse('//$server');
  final host = uri.host;
  final port = uri.port;
  if (host.isEmpty || port == 0) {
    throw ArgumentError.value(server, 'server', 'must be a host:port address');
  }
  if (InternetAddress.tryParse(host) != null) {
    return server;
  }
  final probe = lookup ?? InternetAddress.lookup;
  final addresses = await probe(host).timeout(timeout);
  InternetAddress? chosen;
  for (final address in addresses) {
    if (address.type == InternetAddressType.IPv4) {
      chosen = address;
      break;
    }
  }
  chosen ??= addresses.isEmpty ? null : addresses.first;
  if (chosen == null) {
    throw const SocketException('stream server resolved to no addresses');
  }
  return chosen.type == InternetAddressType.IPv6
      ? '[${chosen.address}]:$port'
      : '${chosen.address}:$port';
}
