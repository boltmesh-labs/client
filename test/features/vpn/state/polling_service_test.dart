import 'dart:async';

import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/vpn/state/polling_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults honor the backend rate-limit budgets', () {
    final svc = PollingService();
    expect(svc.statusInterval, Env.statusPollInterval);
    expect(svc.healthInterval, PollingService.healthCheckInterval);
    expect(
      svc.backgroundHealthInterval,
      PollingService.backgroundHealthCheckInterval,
    );
  });

  test('start fires both ticks periodically; stop cancels', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(seconds: 60),
        healthInterval: const Duration(seconds: 10),
        // Isolate the periodic behaviour from the one-off early check.
        statusInitialDelay: const Duration(hours: 1),
      );
      var statusTicks = 0;
      var healthTicks = 0;
      svc.start(
        onStatus: () async => statusTicks++,
        onHealth: () async => healthTicks++,
      );
      expect(svc.isRunning, isTrue);

      async.elapse(const Duration(seconds: 30));
      expect(statusTicks, 0);
      expect(healthTicks, 3);

      async.elapse(const Duration(seconds: 30));
      expect(statusTicks, 1);
      expect(healthTicks, 6);

      svc.stop();
      expect(svc.isRunning, isFalse);
      async.elapse(const Duration(minutes: 5));
      expect(statusTicks, 1);
      expect(healthTicks, 6);
    });
  });

  test('restart replaces timers instead of doubling ticks', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(seconds: 60),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(hours: 1),
      );
      var statusTicks = 0;
      svc.start(onStatus: () async => statusTicks++, onHealth: () async {});
      async.elapse(const Duration(seconds: 30));
      expect(statusTicks, 0);

      svc.start(onStatus: () async => statusTicks++, onHealth: () async {});
      async.elapse(const Duration(seconds: 59));
      expect(statusTicks, 0, reason: 'restarted timer fires only at 60s');
      async.elapse(const Duration(seconds: 1));
      // Exactly one timer: a doubled timer would have fired twice by now.
      expect(statusTicks, 1);

      svc.stop();
    });
  });

  test('restart cannot overlap an in-flight tick', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(seconds: 60),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(hours: 1),
      );
      var calls = 0;
      final gate = Completer<void>();
      svc.start(
        onStatus: () async {
          calls++;
          await gate.future;
        },
        onHealth: () async {},
      );

      async.elapse(const Duration(seconds: 60));
      expect(calls, 1, reason: 'single-flight holds the first tick in flight');

      // Restart while the first status tick is still awaiting: the new timer
      // must not run a second concurrent tick.
      svc.start(onStatus: () async => calls++, onHealth: () async {});
      async.elapse(const Duration(seconds: 60));
      expect(calls, 1);

      // Once the in-flight tick settles, its `finally` clears the flag and the
      // restarted cadence resumes.
      gate.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 60));
      expect(calls, 2);

      svc.stop();
    });
  });

  test('a throwing tick does not kill the timer', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(seconds: 60),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(hours: 1),
      );
      var calls = 0;
      svc.start(
        onStatus: () async {
          calls++;
          throw StateError('boom');
        },
        onHealth: () async {},
      );

      async.elapse(const Duration(seconds: 180));
      expect(calls, 3);

      svc.stop();
    });
  });

  test('early status check fires once ahead of the periodic interval', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(hours: 1),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(seconds: 30),
      );
      var statusTicks = 0;
      svc.start(onStatus: () async => statusTicks++, onHealth: () async {});

      async.elapse(const Duration(seconds: 90));
      expect(statusTicks, 1);

      svc.stop();
    });
  });

  test('stop cancels the early status check', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(hours: 1),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(seconds: 30),
      );
      var statusTicks = 0;
      svc.start(onStatus: () async => statusTicks++, onHealth: () async {});
      svc.stop();
      expect(svc.isRunning, isFalse);

      async.elapse(const Duration(minutes: 2));
      expect(statusTicks, 0);
    });
  });

  test('early delay stays well under the rate-limit floor', () {
    expect(
      PollingService.statusFirstPollDelay,
      lessThan(Env.statusPollInterval),
    );
  });

  test('background start uses the slow health cadence', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(hours: 1),
        healthInterval: const Duration(hours: 1),
        backgroundHealthInterval: const Duration(seconds: 30),
        statusInitialDelay: const Duration(hours: 1),
      );
      var healthTicks = 0;
      svc.start(
        onStatus: () async {},
        onHealth: () async => healthTicks++,
        background: true,
      );

      async.elapse(const Duration(seconds: 90));
      expect(healthTicks, 3);

      svc.stop();
    });
  });

  test('foreground start ignores the background cadence', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(hours: 1),
        healthInterval: const Duration(seconds: 10),
        backgroundHealthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(hours: 1),
      );
      var healthTicks = 0;
      svc.start(onStatus: () async {}, onHealth: () async => healthTicks++);

      async.elapse(const Duration(seconds: 30));
      expect(healthTicks, 3);

      svc.stop();
    });
  });

  test('earlyStatus:false arms no one-off status check', () {
    fakeAsync((async) {
      final svc = PollingService(
        statusInterval: const Duration(hours: 1),
        healthInterval: const Duration(hours: 1),
        statusInitialDelay: const Duration(seconds: 30),
      );
      var statusTicks = 0;
      svc.start(
        onStatus: () async => statusTicks++,
        onHealth: () async {},
        earlyStatus: false,
      );

      async.elapse(const Duration(minutes: 2));
      expect(statusTicks, 0);

      svc.stop();
    });
  });

  test('background cadence is slower than the foreground one', () {
    expect(
      PollingService.backgroundHealthCheckInterval,
      greaterThan(PollingService.healthCheckInterval),
    );
  });
}
