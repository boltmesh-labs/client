// Shared, pure `host:port` helpers for WireGuard endpoints, the stream rung's
// TLS dial target, and the transport's loopback addresses. No Flutter /
// `dart:io` dependencies.
library;

/// The host and port halves of a `host:port` string, or null when the value
/// has no separable shape.
///
/// The bracketed form is tried first because it is the only unambiguous IPv6
/// one, and `[^:]+` in the plain pattern already refuses anything containing a
/// colon, so a bare IPv6 literal (`2001:db8::9:51820`) is refused rather than
/// misread as a host with a port — callers that only compare endpoints treat
/// that as unverifiable, and callers that dial reject it.
///
/// The port is parsed but not range-checked: a dialer validates the range, an
/// endpoint comparison does not need to.
(String, int)? splitHostPort(String endpoint) {
  final v = endpoint.trim();
  final bracketed = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(v);
  if (bracketed != null) {
    final port = int.tryParse(bracketed.group(2)!);
    return port == null ? null : (bracketed.group(1)!, port);
  }
  final plain = RegExp(r'^([^:]+):(\d+)$').firstMatch(v);
  if (plain == null) return null;
  final port = int.tryParse(plain.group(2)!);
  return port == null ? null : (plain.group(1)!, port);
}

/// Formats `host:port`, bracketing a bare IPv6 literal (the only unambiguous
/// IPv6 form) and leaving an already-bracketed host alone.
String formatHostPort(String host, int port) {
  final h = host.trim();
  if (h.contains(':') && !(h.startsWith('[') && h.endsWith(']'))) {
    return '[$h]:$port';
  }
  return '$h:$port';
}
