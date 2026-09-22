import 'dart:async';
import 'dart:io';

import 'gateway_probe.dart';

/// UDP echo to the in-tunnel gateway. Tri-state: true = a datagram came
/// back within [timeout] (data path alive), false = the probe was sent but
/// nothing answered (corroborated-dead), null = the probe could not even be
/// set up/sent (unknown — a local socket error must never read as death).
Future<bool?> echoDns(String ip, {Duration? timeout}) async {
  final budget = timeout ?? const Duration(seconds: 2);
  RawDatagramSocket? socket;
  try {
    final target = InternetAddress(ip);
    final bindAddr = target.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4;
    socket = await RawDatagramSocket.bind(bindAddr, 0).timeout(budget);
    socket.send(buildDnsQuery(), target, 53);
    final completer = Completer<bool>();
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket?.receive();
        if (datagram != null && !completer.isCompleted) {
          completer.complete(true);
        }
      }
    });
    return await completer.future.timeout(budget, onTimeout: () => false);
  } catch (_) {
    // Never sent (bind/send failed): absence of evidence, not death.
    return null;
  } finally {
    try {
      socket?.close();
    } catch (_) {}
  }
}
