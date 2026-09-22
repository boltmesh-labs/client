// Web/other non-io stub: no UDP sockets without dart:io. Null (unknown)
// means the caller must never read it as a dead tunnel.
import 'dart:async';

/// UDP echo to [ip]; null when unsupported (unknown, never death).
Future<bool?> echoDns(String ip, {Duration? timeout}) async => null;
