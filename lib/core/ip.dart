// Shared, pure IP address helpers: parse/format/validate IPv4 + IPv6, plus
// the loopback and private-unicast predicates. Used by the WireGuard config
// builder (`vpn/data/wg_conf.dart`) and the in-tunnel gateway probe
// (`vpn/data/gateway_probe.dart`). No Flutter/`dart:io` dependencies.

/// Parses a dotted-quad IPv4 address into its 32-bit value.
/// Throws [ArgumentError] when [ip] is malformed.
BigInt parseIpV4(String ip) {
  final octets = ip.split('.');
  if (octets.length != 4 ||
      octets.any((octet) => !RegExp(r'^\d{1,3}$').hasMatch(octet))) {
    throw ArgumentError('Bad IPv4 address: $ip');
  }
  var v = BigInt.zero;
  for (final o in octets) {
    final b = int.parse(o);
    if (b > 255) throw ArgumentError('Bad IPv4 address: $ip');
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
  final compression = ip.indexOf('::');
  final words = <int>[];

  if (compression >= 0) {
    if (ip.indexOf('::', compression + 2) >= 0) {
      throw ArgumentError('Bad IPv6 address: $ip');
    }
    final left = ip.substring(0, compression);
    final right = ip.substring(compression + 2);
    final leftWords = _parseIpV6Side(left, ip, allowEmbeddedIpV4: false);
    final rightWords = _parseIpV6Side(right, ip, allowEmbeddedIpV4: true);
    final explicitLength = leftWords.length + rightWords.length;
    if (explicitLength >= 8) throw ArgumentError('Bad IPv6 address: $ip');
    words
      ..addAll(leftWords)
      ..addAll(List.filled(8 - explicitLength, 0))
      ..addAll(rightWords);
  } else {
    words.addAll(_parseIpV6Side(ip, ip, allowEmbeddedIpV4: true));
    if (words.length != 8) throw ArgumentError('Bad IPv6 address: $ip');
  }

  var v = BigInt.zero;
  for (final word in words) {
    v = (v << 16) + BigInt.from(word);
  }
  return v;
}

List<int> _parseIpV6Side(
  String side,
  String original, {
  required bool allowEmbeddedIpV4,
}) {
  if (side.isEmpty) return const [];
  final parts = side.split(':');
  final words = <int>[];
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part.isEmpty) throw ArgumentError('Bad IPv6 address: $original');
    if (part.contains('.')) {
      if (!allowEmbeddedIpV4 || i != parts.length - 1) {
        throw ArgumentError('Bad IPv6 address: $original');
      }
      final v4 = parseIpV4(part);
      words.add(((v4 >> 16) & BigInt.from(0xffff)).toInt());
      words.add((v4 & BigInt.from(0xffff)).toInt());
      continue;
    }
    if (!RegExp(r'^[0-9A-Fa-f]{1,4}$').hasMatch(part)) {
      throw ArgumentError('Bad IPv6 address: $original');
    }
    words.add(int.parse(part, radix: 16));
  }
  return words;
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
  final parts = token.trim().split('/');
  if (parts.length > 2) return null;
  final bare = parts.first.trim();
  if (bare.isEmpty) return null;

  final isV6 = bare.contains(':');
  if (parts.length == 2) {
    final prefix = int.tryParse(parts[1].trim());
    if (prefix == null || prefix < 0 || prefix > (isV6 ? 128 : 32)) {
      return null;
    }
  }
  if (isV6) return isValidIpV6(bare) ? bare : null;
  return isValidIpV4(bare) ? bare : null;
}

/// True for loopback addresses (`127.0.0.0/8`, `::1`).
bool isLoopbackIp(String ip) {
  final value = ip.trim();
  if (value.isEmpty) return false;
  if (value.contains(':')) {
    try {
      return parseIpV6(value) == BigInt.one;
    } on ArgumentError {
      return false;
    }
  }
  try {
    return (parseIpV4(value) >> 24) == BigInt.from(127);
  } on ArgumentError {
    return false;
  }
}

/// True for RFC1918 v4 and ULA/link-local v6 — the ranges an overlay
/// gateway lives in. Loopback is excluded on purpose: probing `127.x`
/// would test the host stack, not the tunnel.
bool isPrivateUnicastIp(String ip) {
  final value = ip.trim();
  if (value.isEmpty) return false;
  try {
    if (value.contains(':')) {
      final v6 = parseIpV6(value);
      final firstByte = (v6 >> 120) & BigInt.from(0xff);
      final firstTenBits = (v6 >> 118) & BigInt.from(0x3ff);
      return firstByte == BigInt.from(0xfc) ||
          firstByte == BigInt.from(0xfd) ||
          firstTenBits == BigInt.from(0x3fa);
    }
    final v4 = parseIpV4(value);
    return (v4 >> 24) == BigInt.from(10) ||
        (v4 >= BigInt.from(0xc0a80000) && v4 <= BigInt.from(0xc0a8ffff)) ||
        (v4 >= BigInt.from(0xac100000) && v4 <= BigInt.from(0xac1fffff));
  } on ArgumentError {
    return false;
  }
}
