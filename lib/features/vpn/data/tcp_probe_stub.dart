// Web/other non-io stub: no sockets without dart:io. Null (unknown)
// means the caller must fail open onto the demote it was gating.
import 'dart:async';

/// TCP connect to [host]:[port]; null when unsupported (unknown, never death).
Future<bool?> tcpConnect(String host, int port, Duration timeout) async => null;
