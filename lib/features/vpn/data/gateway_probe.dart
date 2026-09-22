import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ip.dart';
import 'gateway_probe_stub.dart'
    if (dart.library.io) 'gateway_probe_io.dart'
    as probe_io;

/// Layer 1: in-tunnel gateway echo over the TUN interface.
///
/// The target is the first probeable IP in `DialParams.wgDns` (private
/// overlay DNS preferred, e.g. `10.8.0.1`; otherwise the first public
/// non-loopback server — every configured DNS server is pinned inside the
/// tunnel with a /32 host route, so its echo proves the WireGuard data path
/// plus kernel routing without touching the WAN). A reply proves the data
/// path alive, so a stale handshake alone must not heal. No probeable IP
/// means the probe is skipped (returns null = unknown, never healthy on its
/// own).
abstract class GatewayProbe {
  /// Sends a minimal DNS query to [ip]. Tri-state: true = a datagram came
  /// back within [timeout] (data path alive), false = the probe was sent
  /// but nothing answered (corroborated-dead), null = errored/unsupported
  /// (unknown, never proof of death on its own). Never throws.
  Future<bool?> echoDns(String ip, {Duration timeout});
}

/// UDP gateway probe (native platforms via `dart:io`).
class UdpGatewayProbe implements GatewayProbe {
  @override
  Future<bool?> echoDns(
    String ip, {
    Duration timeout = const Duration(seconds: 2),
  }) => probe_io.echoDns(ip, timeout: timeout);
}

final gatewayProbeProvider = Provider<GatewayProbe>((_) => UdpGatewayProbe());

/// First probeable IP in a comma/space-separated `wgDns` value, or null
/// when there is none (empty, malformed). Private (overlay) addresses win;
/// otherwise the first public non-loopback server is used — every
/// configured DNS server is pinned inside the tunnel with a /32 host route
/// (see `wg_conf.dart` `allowedIPs`), so its echo still proves the data
/// path. Loopback is excluded on purpose: probing `127.x` would test the
/// host stack, not the tunnel.
String? firstDnsProbeIp(String wgDns) {
  final ips = wgDns.split(RegExp(r'[,\s]+')).map(bareIp).nonNulls.toList();
  for (final ip in ips) {
    if (isPrivateUnicastIp(ip)) return ip;
  }
  for (final ip in ips) {
    if (!isLoopbackIp(ip)) return ip;
  }
  return null;
}

/// Minimal DNS A-query for `health.boltmesh` (any UDP reply counts as
/// alive; the answer itself is irrelevant). Pure so it can be unit-tested.
Uint8List buildDnsQuery() {
  final name = 'health.boltmesh'.split('.');
  final data = BytesBuilder();
  data.add(const [
    0x12,
    0x34,
    0x01,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  for (final label in name) {
    final units = label.codeUnits;
    data.addByte(units.length);
    data.add(units);
  }
  data.add(const [0x00, 0x00, 0x01, 0x00, 0x01]);
  return data.toBytes();
}
