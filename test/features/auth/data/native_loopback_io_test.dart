import 'dart:io';

import 'package:boltmesh/features/auth/data/native_loopback_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns a real, still-bindable IPv4 loopback port', () async {
    final port = await findFreeLoopbackPort();
    expect(port, greaterThan(0));

    final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    try {
      expect(rebound.port, port);
    } finally {
      await rebound.close();
    }
  });

  test('repeated calls always yield a usable port', () async {
    for (var i = 0; i < 5; i++) {
      final port = await findFreeLoopbackPort();
      expect(port, inInclusiveRange(1, 65535));
    }
  });
}
