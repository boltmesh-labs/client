// Mirrors backend/app/vpn/utils.py `build_wireguard_conf_string`:
// host-prefix Address (/32 IPv4, /128 IPv6), IPv6 endpoint bracketing,
// full-tunnel AllowedIPs by default, PersistentKeepalive 25.
//
// Split tunnel (`allowLocal`, the default): RFC1918/link-local/multicast
// subnets stay off the tunnel so printers, smart-home gear, and LAN servers
// keep working. Implemented as an AllowedIPs complement list (the only
// cross-platform routing knob `wireguard_flutter_plus` exposes — `startVpn`
// takes just `wgQuickConfig` plus app-level include/exclude lists), with
// explicit host routes re-added for the overlay IP and DNS so those always
// stay inside the tunnel even when they live in 10.x.
// Strict mode (`allowLocal: false`) restores 0.0.0.0/0 + ::/0 and forces
// everything, LAN included, through the tunnel.
//
// NOTE: a full-tunnel default route also captures the control plane's
// underlay (SSH-based port-forwards die with it, LAN backends go dark).
// The app therefore stops the tunnel before every control-plane POST
// (see ConnectionController.switchServer/disconnect) — never move API
// calls back inside a live tunnel.

import '../../../core/ip.dart';

String normalizeAddressCidr(String assignedIp) {
  final v = assignedIp.trim();
  final bare = v.contains('/') ? v.split('/').first.trim() : v;
  return '$bare/${bare.contains(':') ? 128 : 32}';
}

String formatEndpoint(String host, int port) {
  final h = host.trim();
  if (h.contains(':') && !(h.startsWith('[') && h.endsWith(']'))) {
    return '[$h]:$port';
  }
  return '$h:$port';
}

/// Throws [ArgumentError] when [value] contains an ASCII control character
/// (including CR/LF/NUL). Used to keep a single interpolated value from
/// injecting an extra directive into the line-oriented config.
void _requireNoControl(String value, String field) {
  for (final rune in value.runes) {
    if (rune < 0x20 || rune == 0x7f) {
      throw ArgumentError('$field contains a control character.');
    }
  }
}

/// Splits [dns] on commas/whitespace and rejoins with `, `, so a value
/// carrying a newline can never reach the rendered `DNS =` line. Token
/// validity (each must be an IP) is enforced by [allowedIPs].
String _normalizeDns(String dns) =>
    dns.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).join(', ');

String buildWgQuickConfig({
  required String privateKey,
  required String assignedIp,
  required String serverPublicKey,
  required String endpointHost,
  required int endpointPort,
  required String dns,
  bool allowLocal = true,
}) {
  if (privateKey.trim().isEmpty) {
    throw ArgumentError('Missing WireGuard private key.');
  }
  if (assignedIp.trim().isEmpty) {
    throw ArgumentError('Missing assigned IP address.');
  }
  if (serverPublicKey.trim().isEmpty) {
    throw ArgumentError('Missing server public key.');
  }
  if (endpointHost.trim().isEmpty) {
    throw ArgumentError('Missing endpoint host.');
  }
  if (dns.trim().isEmpty) {
    throw ArgumentError('Missing DNS servers.');
  }
  // WireGuard config is line-oriented, so every interpolated field must be
  // a single line. Without this, a newline in a discovery/backend-supplied
  // host or key would break out of its line and inject extra directives
  // (e.g. a rogue `[Peer]`). DNS is handled by [_normalizeDns] instead,
  // since whitespace there is a legitimate separator.
  _requireNoControl(privateKey, 'privateKey');
  _requireNoControl(serverPublicKey, 'serverPublicKey');
  _requireNoControl(endpointHost, 'endpointHost');
  _requireNoControl(assignedIp, 'assignedIp');
  final normalizedDns = _normalizeDns(dns);
  final endpoint = formatEndpoint(endpointHost, endpointPort);
  final address = normalizeAddressCidr(assignedIp);
  final priv = privateKey.trim();
  final srvPub = serverPublicKey.trim();
  final allowedIps = allowedIPs(
    allowLocal: allowLocal,
    assignedIp: assignedIp,
    dns: normalizedDns,
  );
  return '[Interface]\n'
      'PrivateKey = $priv\n'
      'Address = $address\n'
      'DNS = $normalizedDns\n'
      '\n'
      '[Peer]\n'
      'PublicKey = $srvPub\n'
      'Endpoint = $endpoint\n'
      'AllowedIPs = $allowedIps\n'
      'PersistentKeepalive = 25\n';
}

/// Subnets kept off the tunnel in split mode: RFC1918 private ranges,
/// link-local, and multicast (v4) / unique-local, link-local, multicast
/// (v6). Everything else — including the public internet — stays routed.
const localExcludedV4 = <String>[
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '224.0.0.0/4',
];

const localExcludedV6 = <String>['fc00::/7', 'fe80::/10', 'ff00::/8'];

/// AllowedIPs line for [buildWgQuickConfig].
///
/// Strict mode returns the classic full tunnel. Split mode returns the
/// complement of [localExcludedV4]/[localExcludedV6] plus explicit host
/// routes for the overlay IP and every DNS server, so those stay inside
/// the tunnel even when they sit in an excluded range (e.g. `10.8.0.1`).
/// WireGuard resolves overlaps by longest prefix, so the /32s win over the
/// LAN exclusion. Throws [ArgumentError] on an unparseable overlay/DNS IP
/// (fail closed: never emit a config that silently leaks overlay traffic
/// onto the LAN).
String allowedIPs({
  required bool allowLocal,
  required String assignedIp,
  required String dns,
}) {
  if (!allowLocal) return '0.0.0.0/0, ::/0';
  final cidrs = [
    ..._subtractCidrs('0.0.0.0/0', localExcludedV4, isV6: false),
    ..._subtractCidrs('::/0', localExcludedV6, isV6: true),
    _hostRoute(assignedIp),
    for (final server in dns.split(RegExp(r'[,\s]+')))
      if (server.trim().isNotEmpty) _hostRoute(server),
  ];
  return cidrs.join(', ');
}

/// `10.8.0.5` → `10.8.0.5/32`, `fd00::5` → `fd00::5/128`.
String _hostRoute(String ip) {
  final bare = ip.contains('/') ? ip.split('/').first.trim() : ip.trim();
  if (bare.isEmpty) throw ArgumentError('Missing IP address.');
  if (bare.contains(':')) {
    parseIpV6(bare); // validates; throws ArgumentError when malformed
    return '$bare/128';
  }
  parseIpV4(bare);
  return '$bare/32';
}

/// Complement of [excluded] inside [full] as a minimal CIDR list.
/// Generic over address length so v4 (32-bit) and v6 (128-bit) share it.
List<String> _subtractCidrs(
  String full,
  List<String> excluded, {
  required bool isV6,
}) {
  final bits = isV6 ? 128 : 32;
  final parse = isV6 ? parseIpV6 : parseIpV4;
  final format = isV6 ? formatIpV6 : formatIpV4;
  final fullRange = _cidrRange(full, parse, bits);
  final holes =
      excluded
          .map((c) => _cidrRange(c, parse, bits))
          .where(
            (h) => h.$2 >= fullRange.$1 && h.$1 <= fullRange.$2,
          ) // keep overlaps only
          .map(
            (h) => (
              h.$1 < fullRange.$1 ? fullRange.$1 : h.$1,
              h.$2 > fullRange.$2 ? fullRange.$2 : h.$2,
            ),
          )
          .toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <String>[];
  var cursor = fullRange.$1;
  for (final hole in _mergeRanges(holes)) {
    if (cursor < hole.$1) {
      for (final r in _rangeToCidrs(cursor, hole.$1 - BigInt.one, bits)) {
        out.add('${format(r.$1)}/${r.$2}');
      }
    }
    if (cursor <= hole.$2) cursor = hole.$2 + BigInt.one;
  }
  if (cursor <= fullRange.$2) {
    for (final r in _rangeToCidrs(cursor, fullRange.$2, bits)) {
      out.add('${format(r.$1)}/${r.$2}');
    }
  }
  return out;
}

(BigInt, BigInt) _cidrRange(
  String cidr,
  BigInt Function(String) parse,
  int bits,
) {
  final parts = cidr.trim().split('/');
  if (parts.length != 2) throw ArgumentError('Bad CIDR: $cidr');
  final prefix =
      int.tryParse(parts[1].trim()) ?? (throw ArgumentError('Bad CIDR: $cidr'));
  if (prefix < 0 || prefix > bits) throw ArgumentError('Bad CIDR: $cidr');
  final addr = parse(parts[0].trim());
  final mask = prefix == 0
      ? BigInt.zero
      : ((BigInt.one << prefix) - BigInt.one) << (bits - prefix);
  final base = addr & mask;
  return (base, base + (BigInt.one << (bits - prefix)) - BigInt.one);
}

List<(BigInt, BigInt)> _mergeRanges(List<(BigInt, BigInt)> ranges) {
  final merged = <(BigInt, BigInt)>[];
  for (final r in ranges) {
    if (merged.isNotEmpty && r.$1 <= merged.last.$2 + BigInt.one) {
      if (r.$2 > merged.last.$2) {
        merged[merged.length - 1] = (merged.last.$1, r.$2);
      }
    } else {
      merged.add(r);
    }
  }
  return merged;
}

/// Minimal CIDR cover of `[start, end]`: at each step take the largest
/// aligned block that fits in the remainder.
List<(BigInt, int)> _rangeToCidrs(BigInt start, BigInt end, int bits) {
  final out = <(BigInt, int)>[];
  var s = start;
  while (s <= end) {
    final align = s == BigInt.zero
        ? BigInt.one << bits
        : s & -s; // lowest set bit = max aligned block
    var size = align;
    final remaining = end - s + BigInt.one;
    while (size > remaining) {
      size >>= 1;
    }
    out.add((s, bits - (size.bitLength - 1)));
    s += size;
  }
  return out;
}
