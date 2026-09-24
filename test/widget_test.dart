import 'dart:async';

import 'package:boltmesh/features/auth/data/session_store.dart';
import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:boltmesh/features/vpn/data/backend_health.dart';
import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConnectionController extends ConnectionController {
  @override
  ConnState build() => const ConnState();

  @override
  Future<void> ensureProvisioned({String? regionId, String? serverId}) async {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> quickConnect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> releaseDevice() async {}

  @override
  Future<void> switchServer({
    required String? regionId,
    required String? serverId,
    bool explicitTarget = true,
    bool pinTarget = true,
  }) async {}

  @override
  Future<void> selectAuto() async {}
}

class _FakeSessionStore extends SessionStore {
  const _FakeSessionStore();

  @override
  Future<String?> apiToken() async => null;

  @override
  Future<String?> refreshToken() async => null;

  @override
  Future<DateTime?> accessExpiry() async => null;

  @override
  Future<String?> authUsername() async => null;
}

class _FakeDeviceStore extends DeviceStore {
  _FakeDeviceStore();

  @override
  Future<String?> deviceName() async => null;

  @override
  Future<bool> allowLocal() async => true;

  @override
  Future<void> setAllowLocal(bool v) async {}
}

/// Device store whose LAN preference never resolves (loading state).
class _PendingDeviceStore extends DeviceStore {
  _PendingDeviceStore();

  @override
  Future<String?> deviceName() async => null;

  @override
  Future<bool> allowLocal() => Completer<bool>().future;
}

/// Device store whose LAN preference read fails.
class _ErrorDeviceStore extends DeviceStore {
  _ErrorDeviceStore();

  @override
  Future<String?> deviceName() async => null;

  @override
  Future<bool> allowLocal() async => throw StateError('locked');
}

class _AuthedController extends AuthController {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, username: 'tester');
}

class _UnauthedController extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

/// Call order probe for the logout/forget-device wiring in SettingsScreen.
final _callOrder = <String>[];

class _OrderConnectionController extends _FakeConnectionController {
  @override
  Future<void> disconnect() async {
    _callOrder.add('disconnect');
  }

  @override
  Future<void> releaseDevice() async {
    _callOrder.add('release');
  }

  @override
  Future<void> forgetDevice() async {
    // The widget test only observes that the button routes to the controller
    // entry point; the stop-tunnel-then-wipe ordering is covered against the
    // real controller in `tunnel_lifecycle_test.dart`.
    _callOrder.add('forget');
  }
}

class _ErrorConnectionController extends _FakeConnectionController {
  @override
  ConnState build() => const ConnState(phase: ConnPhase.error, message: 'boom');
}

/// Release that throws: logout must still proceed.
class _ThrowingReleaseController extends _FakeConnectionController {
  @override
  Future<void> releaseDevice() async {
    _callOrder.add('release');
    throw StateError('release failed');
  }
}

const _trafficDial = DialParams(
  deviceId: 'dev-1',
  assignedIp: '10.8.0.2',
  serverId: 's-1',
  serverName: 'one',
  endpoint: 'one.example.com',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  wgPublicKey: 'srv-pub',
);

/// Connected controller with preset traffic counters (no tunnel involved).
class _TrafficConnectionController extends _FakeConnectionController {
  @override
  ConnState build() => const ConnState(
    phase: ConnPhase.connected,
    message: 'Connected',
    dial: _trafficDial,
    rxBytes: 12 * 1024 * 1024,
    txBytes: 2 * 1024 * 1024,
  );
}

class _ConnectedConnectionController extends _FakeConnectionController {
  @override
  ConnState build() => const ConnState(
    phase: ConnPhase.connected,
    message: 'Connected',
    dial: _trafficDial,
  );
}

/// Error-phase controller whose last failure is a 429 cooldown: the hero
/// Connect button must snack it (a no-op quickConnect leaves the state on).
class _RateLimitedConnectionController extends _FakeConnectionController {
  @override
  ConnState build() => const ConnState(
    phase: ConnPhase.error,
    message: 'Rate limit reached. Please wait 42s.',
    opFailed: true,
  );
}

/// Connected controller carrying an `opFailed` from an earlier op: tapping
/// Disconnect must NOT snack it (the local teardown always succeeds).
class _ConnectedOpFailedController extends _FakeConnectionController {
  @override
  ConnState build() => const ConnState(
    phase: ConnPhase.connected,
    message: 'Switch failed, still on one.',
    dial: _trafficDial,
    opFailed: true,
  );
}

class _OrderAuthController extends AuthController {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, username: 'tester');

  @override
  Future<void> logout() async {
    _callOrder.add('logout');
  }
}

class _OrderSessionStore extends SessionStore {
  const _OrderSessionStore();

  @override
  Future<String?> apiToken() async => null;

  @override
  Future<String?> refreshToken() async => null;

  @override
  Future<DateTime?> accessExpiry() async => null;

  @override
  Future<String?> authUsername() async => 'tester';
}

class _OrderDeviceStore extends DeviceStore {
  _OrderDeviceStore();

  @override
  Future<String?> deviceId() async => null;

  @override
  Future<String?> deviceName() async => null;

  @override
  Future<bool> allowLocal() async => true;

  @override
  Future<void> setAllowLocal(bool v) async {}

  @override
  Future<void> clearDevice() async {}
}

/// Shared shell for the widget tests: the real [BoltMeshApp] with the
/// connection/auth/store slices and backend health overridden. Health
/// defaults to reachable, because the Home watches the continuous `/health`
/// stream and tests must not run real probe I/O; dedicated tests pass
/// unreachable/unknown instead.
ProviderScope vpnScope({
  required ConnectionController Function() connection,
  required AuthController Function() auth,
  BackendHealth health = BackendHealth.reachable,
  DeviceStore? deviceStore,
  SessionStore sessionStore = const _FakeSessionStore(),
}) {
  return ProviderScope(
    overrides: [
      backendHealthProvider.overrideWith((ref) => Stream.value(health)),
      connectionProvider.overrideWith(connection),
      deviceStoreProvider.overrideWithValue(deviceStore ?? _FakeDeviceStore()),
      sessionStoreProvider.overrideWithValue(sessionStore),
      authProvider.overrideWith(auth),
      // The shell now keeps every tab mounted (IndexedStack), so the Regions
      // screen subscribes at startup: pin discovery to an empty list so no
      // test touches the network.
      regionsProvider.overrideWithValue(const AsyncValue.data(<Region>[])),
    ],
    child: const BoltMeshApp(),
  );
}

ProviderScope logoutScope() => vpnScope(
  connection: _OrderConnectionController.new,
  auth: _OrderAuthController.new,
  deviceStore: _OrderDeviceStore(),
  sessionStore: const _OrderSessionStore(),
);

ProviderScope testScope({bool authenticated = true}) => vpnScope(
  connection: _FakeConnectionController.new,
  auth: authenticated ? _AuthedController.new : _UnauthedController.new,
);

ProviderScope errorScope() => vpnScope(
  connection: _ErrorConnectionController.new,
  auth: _AuthedController.new,
);

ProviderScope trafficScope() => vpnScope(
  connection: _TrafficConnectionController.new,
  auth: _AuthedController.new,
);

ProviderScope connectedScope() => vpnScope(
  connection: _ConnectedConnectionController.new,
  auth: _AuthedController.new,
);

ProviderScope backendScope(BackendHealth health) => vpnScope(
  connection: _FakeConnectionController.new,
  auth: _AuthedController.new,
  health: health,
);

void main() {
  testWidgets('boots to disconnected home with bottom nav', (tester) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    expect(find.text('BoltMesh VPN'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      find.widgetWithText(NavigationDestination, 'Connect'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(NavigationDestination, 'Regions'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(NavigationDestination, 'Settings'),
      findsOneWidget,
    );
  });

  testWidgets('disconnected home offers a hero power button, not a switch', (
    tester,
  ) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.bySemanticsLabel('Connect'), findsOneWidget);
    // No traffic card before the first counter read.
    expect(find.text('Session traffic'), findsNothing);
  });

  testWidgets('bottom nav switches to settings and back', (tester) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as tester'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets('typed settings input survives a tab switch', (tester) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My Laptop');
    await tester.pump();

    // IndexedStack keeps the tab mounted, so the typed value (and its
    // controller state) must survive leaving and returning.
    await tester.tap(find.widgetWithText(NavigationDestination, 'Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    expect(find.text('My Laptop'), findsOneWidget);
  });

  testWidgets('unauthenticated shows the login screen', (tester) async {
    await tester.pumpWidget(testScope(authenticated: false));
    await tester.pumpAndSettle();

    expect(find.text('Username or email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('login form exposes autofill hints and a password tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(testScope(authenticated: false));
    await tester.pumpAndSettle();

    final identifier = tester.widget<TextField>(find.byType(TextField).first);
    expect(identifier.autofillHints, contains(AutofillHints.username));
    final toggle = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.visibility),
    );
    expect(toggle.tooltip, 'Show password');
  });

  testWidgets('logout releases the device before revoking the session', (
    tester,
  ) async {
    _callOrder.clear();
    await tester.pumpWidget(logoutScope());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(_callOrder, ['release', 'logout']);
  });

  testWidgets('logout proceeds even when the device release fails', (
    tester,
  ) async {
    _callOrder.clear();
    await tester.pumpWidget(
      vpnScope(
        connection: _ThrowingReleaseController.new,
        auth: _OrderAuthController.new,
        deviceStore: _OrderDeviceStore(),
        sessionStore: const _OrderSessionStore(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    // The failed release is logged, not fatal: the user is still signed out.
    expect(_callOrder, ['release', 'logout']);
  });

  testWidgets('forget device routes through the controller and confirms', (
    tester,
  ) async {
    _callOrder.clear();
    await tester.pumpWidget(logoutScope());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(_callOrder, ['forget']);
    expect(
      find.text('Device cleared. Next connect reprovisions.'),
      findsOneWidget,
    );
  });

  testWidgets('connected home shows disconnect hero and traffic card', (
    tester,
  ) async {
    await tester.pumpWidget(trafficScope());
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Disconnect'), findsOneWidget);
    expect(find.bySemanticsLabel('Disconnect'), findsOneWidget);
    expect(find.text('Session traffic'), findsOneWidget);
    expect(find.text('Download 12.0 MB · Upload 2.0 MB'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Downloaded 12.0 MB, uploaded 2.0 MB'),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('connected home hides the traffic card without counters', (
    tester,
  ) async {
    await tester.pumpWidget(connectedScope());
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Disconnect'), findsOneWidget);
    expect(find.text('Session traffic'), findsNothing);
  });

  testWidgets('error home offers connect via the hero button', (tester) async {
    await tester.pumpWidget(errorScope());
    await tester.pumpAndSettle();

    expect(find.text('Error'), findsOneWidget);
    // No separate retry button: the hero power button shows Connect in
    // the error phase and reconciles via config/connect.
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('home connect tap snacks a rate-limit failure', (tester) async {
    await tester.pumpWidget(
      vpnScope(
        connection: _RateLimitedConnectionController.new,
        auth: _AuthedController.new,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Rate limit reached. Please wait 42s.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('home disconnect tap never snacks a deferred release', (
    tester,
  ) async {
    await tester.pumpWidget(
      vpnScope(
        connection: _ConnectedOpFailedController.new,
        auth: _AuthedController.new,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('settings exposes a single outlined action', (tester) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Forget device'),
      findsOneWidget,
    );
  });

  testWidgets('settings shows the LAN access toggle defaulting to on', (
    tester,
  ) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Allow Local Network Access'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isTrue);
  });

  testWidgets('flipping the LAN toggle while idle saves and snacks', (
    tester,
  ) async {
    await tester.pumpWidget(testScope());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      find.text('Network setting saved. Applies on next connect.'),
      findsOneWidget,
    );
  });

  testWidgets('LAN toggle shows no on/off switch while its value is unknown', (
    tester,
  ) async {
    await tester.pumpWidget(
      vpnScope(
        connection: _FakeConnectionController.new,
        auth: _AuthedController.new,
        deviceStore: _PendingDeviceStore(),
      ),
    );
    // The unresolved LAN read keeps a CircularProgressIndicator animating, so
    // pumpAndSettle would never return: pump fixed frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Allow Local Network Access'), findsOneWidget);
    // An unknown value must not render as ON.
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('LAN toggle reports an unreadable value instead of ON', (
    tester,
  ) async {
    await tester.pumpWidget(
      vpnScope(
        connection: _FakeConnectionController.new,
        auth: _AuthedController.new,
        deviceStore: _ErrorDeviceStore(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text("Couldn't read the current setting."), findsOneWidget);
  });

  testWidgets('backend unreachable disables connect and shows a banner', (
    tester,
  ) async {
    await tester.pumpWidget(backendScope(BackendHealth.unreachable));
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Connect'),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text(
        'Backend unreachable. Connect is disabled until the server is reachable.',
      ),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('unknown backend health fails open', (tester) async {
    await tester.pumpWidget(backendScope(BackendHealth.unknown));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Connect'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.byType(OutlinedButton), findsNothing);
  });
}
