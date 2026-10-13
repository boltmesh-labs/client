import 'package:boltmesh/features/vpn/state/tunnel_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final origin = DateTime.utc(2026);

  test('start anchors the fresh clock and clears the previous generation', () {
    final health = TunnelHealth()
      ..connectedAt = origin
      ..statusAnswered = true
      ..deadEchoStrikes = 3;

    final restarted = origin.add(const Duration(minutes: 5));
    health.start(restarted);

    expect(health.connectedAt, restarted);
    expect(health.statusAnswered, isFalse);
    expect(health.deadEchoStrikes, 0);
  });

  test('reset drops every anchor', () {
    final health = TunnelHealth()
      ..connectedAt = origin
      ..statusAnswered = true
      ..deadEchoStrikes = 2;

    health.reset();

    expect(health.connectedAt, isNull);
    expect(health.statusAnswered, isFalse);
    expect(health.deadEchoStrikes, 0);
  });

  test('observeEcho counts performed-dead and clears on alive/unknown', () {
    final health = TunnelHealth();

    health.observeEcho(false);
    health.observeEcho(false);
    expect(health.deadEchoStrikes, 2);

    // Alive proves the data path, so it clears the run outright.
    health.observeEcho(true);
    expect(health.deadEchoStrikes, 0);

    // A skipped/unknown probe is not proof of death either.
    health.observeEcho(false);
    expect(health.deadEchoStrikes, 1);
    health.observeEcho(null);
    expect(health.deadEchoStrikes, 0);
  });
}
