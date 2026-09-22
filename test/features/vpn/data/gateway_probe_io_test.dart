import 'package:boltmesh/features/vpn/data/gateway_probe_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a probe that cannot be sent reports unknown, never death', () async {
    // InternetAddress() rejects the literal before any socket is bound, so
    // this exercises the error path: null (unknown), never false (dead).
    expect(await echoDns('not-an-ip'), isNull);
  });
}
