import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:boltmesh/features/vpn/state/resume_coordinator.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the ordered calls the coordinator makes and pins the auth status.
class _FakeAuthController extends AuthController {
  _FakeAuthController(this.calls, this.authenticated);

  final List<String> calls;
  final bool authenticated;

  @override
  Future<AuthState> build() async => AuthState(
    status: authenticated
        ? AuthStatus.authenticated
        : AuthStatus.unauthenticated,
  );

  @override
  Future<bool> refreshIfExpired({DateTime? now}) async {
    calls.add('refresh');
    return true;
  }
}

class _FakeConnectionController extends ConnectionController {
  _FakeConnectionController(this.calls, this.initial);

  final List<String> calls;
  final ConnState initial;

  @override
  ConnState build() => initial;

  @override
  Future<void> ensureProvisioned({String? regionId, String? serverId}) async {
    calls.add('ensure');
  }

  @override
  Future<void> reconcileColdStart() async => calls.add('reconcile');

  @override
  Future<void> catchUpOnResume({DateTime? now}) async => calls.add('catchUp');

  @override
  void setBackgrounded(bool value) => calls.add('backgrounded:$value');
}

Future<ProviderContainer> makeContainer({
  required List<String> calls,
  bool authenticated = true,
  ConnPhase phase = ConnPhase.idle,
}) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => _FakeAuthController(calls, authenticated),
      ),
      connectionProvider.overrideWith(
        () => _FakeConnectionController(calls, ConnState(phase: phase)),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Settle the async auth build so `.value` is populated when read.
  await container.read(authProvider.future);
  return container;
}

void main() {
  group('ResumeCoordinator.onStartup', () {
    test('authenticated provisions then reconciles', () async {
      final calls = <String>[];
      final container = await makeContainer(calls: calls);

      await ResumeCoordinator(container).onStartup();

      expect(calls, ['ensure', 'reconcile']);
    });

    test('unauthenticated never provisions', () async {
      final calls = <String>[];
      final container = await makeContainer(calls: calls, authenticated: false);

      await ResumeCoordinator(container).onStartup();

      expect(calls, isEmpty);
    });
  });

  group('ResumeCoordinator.onResume', () {
    test(
      'foreground cadence first, then auth, then reconcile while idle',
      () async {
        final calls = <String>[];
        final container = await makeContainer(calls: calls);

        await ResumeCoordinator(container).onResume(now: DateTime.utc(2026));

        expect(calls, ['backgrounded:false', 'refresh', 'reconcile']);
      },
    );

    test(
      'foreground cadence first, then auth, then catch-up when not idle',
      () async {
        final calls = <String>[];
        final container = await makeContainer(
          calls: calls,
          phase: ConnPhase.connected,
        );

        await ResumeCoordinator(container).onResume(now: DateTime.utc(2026));

        expect(calls, ['backgrounded:false', 'refresh', 'catchUp']);
      },
    );

    test('rapid flaps are debounced, later resume runs again', () async {
      final calls = <String>[];
      final container = await makeContainer(calls: calls);
      final coordinator = ResumeCoordinator(container);
      final t0 = DateTime.utc(2026);

      await coordinator.onResume(now: t0);
      await coordinator.onResume(now: t0.add(const Duration(seconds: 1)));
      expect(calls, [
        'backgrounded:false',
        'refresh',
        'reconcile',
        // The debounced resume still restores the cadence.
        'backgrounded:false',
      ]);

      await coordinator.onResume(now: t0.add(const Duration(seconds: 4)));
      expect(calls, [
        'backgrounded:false',
        'refresh',
        'reconcile',
        'backgrounded:false',
        'backgrounded:false',
        'refresh',
        'reconcile',
      ]);
    });

    test('unauthenticated skips the VPN catch-up', () async {
      final calls = <String>[];
      final container = await makeContainer(calls: calls, authenticated: false);

      await ResumeCoordinator(container).onResume(now: DateTime.utc(2026));

      expect(calls, isNot(contains('reconcile')));
      expect(calls, isNot(contains('catchUp')));
    });
  });

  group('ResumeCoordinator.onPause', () {
    test('switches to the background cadence', () async {
      final calls = <String>[];
      final container = await makeContainer(
        calls: calls,
        phase: ConnPhase.connected,
      );

      ResumeCoordinator(container).onPause();

      expect(calls, ['backgrounded:true']);
    });

    test('unauthenticated never touches the connection', () async {
      final calls = <String>[];
      final container = await makeContainer(calls: calls, authenticated: false);

      ResumeCoordinator(container).onPause();

      expect(calls, isEmpty);
    });
  });
}
