// Shared, pure IP address helpers: parse/format/validate IPv4 + IPv6, plus
// the loopback and private-unicast predicates. Used by the WireGuard config
// builder (`vpn/data/wg_conf.dart`) and the in-tunnel gateway probe
// (`vpn/data/gateway_probe.dart`). No Flutter/`dart:io` dependencies.

/// Parses a dotted-quad IPv4 address into its 32-bit value.
/// Throws [ArgumentError] when [ip] is malformed.
BigInt parseIpV4(String ip) {
  final octets = ip.split('.');
  if (octets.length != 4) throw ArgumentError('Bad IPv4 address: $ip');
  var v = BigInt.zero;
  for (final o in octets) {
    final b = int.tryParse(o) ?? (throw ArgumentError('Bad IPv4: $ip'));
    if (b < 0 || b > 255) throw ArgumentError('Bad IPv4 address: $ip');
    v = (v << 8) + BigInt.from(b);
  }
  return v;
}

/// Formats the low 32 bits of [v] as a dotted-quad IPv4 address.
String formatIpV4(BigInt v) {
  final b = List<int>.generate(
    4,
    (i) => ((v >> (8 * (3 - i))) & BigInt.from(0xff)).toInt(),
  );
  return b.join('.');
}

/// Parses an IPv6 address (with `::` compression) into its 128-bit value.
/// Throws [ArgumentError] when [ip] is malformed.
BigInt parseIpV6(String ip) {
  var head = <String>[];
  var tail = <String>[];
  if (ip.contains('::')) {
    final halves = ip.split('::');
    if (halves.length != 2) throw ArgumentError('Bad IPv6 address: $ip');
    if (halves[0].isNotEmpty) head = halves[0].split(':');
    if (halves[1].isNotEmpty) tail = halves[1].split(':');
    if (head.length + tail.length > 7) {
      throw ArgumentError('Bad IPv6 address: $ip');
    }
    head = [
      ...head,
      ...List.filled(8 - head.length - tail.length, '0'),
      ...tail,
    ];
  } else {
    head = ip.split(':');
    if (head.length != 8) throw ArgumentError('Bad IPv6 address: $ip');
  }
  var v = BigInt.zero;
  for (final g in head) {
    final w =
        int.tryParse(g.isEmpty ? '0' : g, radix: 16) ??
        (throw ArgumentError('Bad IPv6 address: $ip'));
    if (w < 0 || w > 0xffff) throw ArgumentError('Bad IPv6 address: $ip');
    v = (v << 16) + BigInt.from(w);
  }
  return v;
}

/// Formats the low 128 bits of [v] as an RFC 5952 IPv6 address (longest run
/// of 2+ zero groups compresses to `::`).
String formatIpV6(BigInt v) {
  final g = List<int>.generate(
    8,
    (i) => ((v >> (16 * (7 - i))) & BigInt.from(0xffff)).toInt(),
  );
  var bestStart = -1;
  var bestLen = 0;
  var curStart = -1;
  var curLen = 0;
  for (var i = 0; i <= 8; i++) {
    if (i < 8 && g[i] == 0) {
      if (curStart < 0) {
        curStart = i;
        curLen = 1;
      } else {
        curLen++;
      }
    } else {
      if (curLen > bestLen) {
        bestStart = curStart;
        bestLen = curLen;
      }
      curStart = -1;
      curLen = 0;
    }
  }
  if (bestLen < 2) {
    return g.map((w) => w.toRadixString(16)).join(':');
  }
  final head = g
      .sublist(0, bestStart)
      .map((w) => w.toRadixString(16))
      .join(':');
  final tail = g
      .sublist(bestStart + bestLen)
      .map((w) => w.toRadixString(16))
      .join(':');
  if (head.isEmpty) return tail.isEmpty ? '::' : '::$tail';
  return tail.isEmpty ? '$head::' : '$head::$tail';
}

/// True when [ip] is a syntactically valid IPv4 address.
bool isValidIpV4(String ip) {
  try {
    parseIpV4(ip);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// True when [ip] is a syntactically valid IPv6 address.
bool isValidIpV6(String ip) {
  try {
    parseIpV6(ip);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// Strips an optional `/prefix` (host routes are emitted as `/32` elsewhere)
/// and returns the bare address, or null when the token is not a plausible
/// IPv4/IPv6 address.
String? bareIp(String token) {
  final bare = token.contains('/') ? token.split('/').first.trim() : token;
  if (bare.isEmpty) return null;
  if (bare.contains(':')) return isValidIpV6(bare) ? bare : null;
  return isValidIpV4(bare) ? bare : null;
}

/// True for loopback addresses (`127.0.0.0/8`, `::1`).
bool isLoopbackIp(String ip) =>
    ip.contains(':') ? ip.toLowerCase() == '::1' : ip.startsWith('127.');

/// True for RFC1918 v4 and ULA/link-local v6 — the ranges an overlay
/// gateway lives in. Loopback is excluded on purpose: probing `127.x`
/// would test the host stack, not the tunnel.
bool isPrivateUnicastIp(String ip) {
  final v = ip.trim();
  if (v.isEmpty) return false;
  if (v.contains(':')) {
    final lower = v.toLowerCase();
    return lower.startsWith('fc') ||
        lower.startsWith('fd') ||
        lower.startsWith('fe80');
  }
  final octets = v.split('.');
  if (octets.length != 4) return false;
  final b = <int>[];
  for (final o in octets) {
    final n = int.tryParse(o);
    if (n == null || n < 0 || n > 255) return false;
    b.add(n);
  }
  if (b[0] == 10) return true;
  if (b[0] == 192 && b[1] == 168) return true;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  return false;
}
