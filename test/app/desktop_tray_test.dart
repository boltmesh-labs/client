import 'package:boltmesh/app/desktop_tray.dart';
import 'package:boltmesh/core/desktop/tray_menu.dart';
import 'package:boltmesh/core/desktop/tray_platform.dart';
import 'package:boltmesh/features/auth/state/auth_providers.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _labels = TrayLabels(
  tooltip: 'BoltMesh VPN',
  show: 'Show BoltMesh',
  hide: 'Hide BoltMesh',
  connect: 'Connect',
  disconnect: 'Disconnect',
  quit: 'Quit',
);

class _FakeTrayPlatform implements TrayPlatform {
  _FakeTrayPlatform({this.available = true});

  /// What [start] answers; false models a desktop with no usable tray host.
  final bool available;

  bool started = false;
  int disposed = 0;
  final applied = <TrayPresentation>[];
  final windowCalls = <String>[];

  void Function()? closeRequested;
  void Function()? iconClicked;
  void Function(TrayAction)? actionPicked;

  @override
  Future<bool> start({
    required void Function() onCloseRequested,
    required void Function() onIconClicked,
    required void Function(TrayAction action) onAction,
  }) async {
    started = true;
    closeRequested = onCloseRequested;
    iconClicked = onIconClicked;
    actionPicked = onAction;
    return available;
  }

  @override
  Future<void> apply(TrayPresentation presentation) async =>
      applied.add(presentation);

  @override
  Future<void> showWindow() async => windowCalls.add('show');

  @override
  Future<void> hideWindow() async => windowCalls.add('hide');

  @override
  Future<void> quit() async => windowCalls.add('quit');

  @override
  Future<void> dispose() async => disposed++;
}

class _FakeAuthController extends AuthController {
  _FakeAuthController(this.authenticated);

  final bool authenticated;

  @override
  Future<AuthState> build() async => AuthState(
    status: authenticated
        ? AuthStatus.authenticated
        : AuthStatus.unauthenticated,
  );
}

class _FakeConnectionController extends ConnectionController {
  _FakeConnectionController(this.calls, this.initial);

  final List<String> calls;
  final ConnState initial;

  @override
  ConnState build() => initial;

  @override
  Future<void> quickConnect() async => calls.add('quickConnect');

  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

Future<ProviderContainer> makeContainer({
  required List<String> calls,
  bool authenticated = true,
  ConnPhase phase = ConnPhase.idle,
}) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _FakeAuthController(authenticated)),
      connectionProvider.overrideWith(
        () => _FakeConnectionController(calls, ConnState(phase: phase)),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(authProvider.future);
  return container;
}

Future<DesktopTray> _startTray(
  ProviderContainer container,
  _FakeTrayPlatform platform,
) async {
  final tray = DesktopTray(
    container: container,
    platform: platform,
    labels: _labels,
  );
  addTearDown(tray.dispose);
  await tray.start();
  // Let the fire-and-forget initial `_sync` settle.
  await Future<void>.delayed(Duration.zero);
  return tray;
}

void main() {
  test('start adds the icon and mirrors the initial menu', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);

    await _startTray(container, platform);

    expect(platform.started, isTrue);
    expect(platform.applied, hasLength(1));
    expect(platform.applied.single.tooltip, 'BoltMesh VPN');
    expect(platform.applied.single.windowVisible, isTrue);
  });

  test('close button hides the window and flips the toggle to Show', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);
    await _startTray(container, platform);

    platform.closeRequested!();
    await Future<void>.delayed(Duration.zero);

    expect(platform.windowCalls, ['hide']);
    expect(platform.applied.last.windowVisible, isFalse);
    expect(platform.applied.last.entries.first.action, TrayAction.show);
  });

  test('icon click toggles the window back and forth', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);
    await _startTray(container, platform);

    platform.iconClicked!();
    await Future<void>.delayed(Duration.zero);
    expect(platform.windowCalls, ['hide']);

    platform.iconClicked!();
    await Future<void>.delayed(Duration.zero);
    expect(platform.windowCalls, ['hide', 'show']);
  });

  test('menu actions route to the connection controller', () async {
    final calls = <String>[];
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: calls);
    await _startTray(container, platform);

    platform.actionPicked!(TrayAction.connect);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['quickConnect']);

    platform.actionPicked!(TrayAction.disconnect);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['quickConnect', 'disconnect']);
  });

  test('Quit terminates through the platform', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);
    await _startTray(container, platform);

    platform.actionPicked!(TrayAction.quit);
    await Future<void>.delayed(Duration.zero);

    expect(platform.windowCalls, ['quit']);
  });

  test('a connected tunnel offers Disconnect from the first menu', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(
      calls: [],
      phase: ConnPhase.connected,
    );

    await _startTray(container, platform);

    expect(
      platform.applied.single.entries.map((e) => e.action),
      contains(TrayAction.disconnect),
    );
  });

  test('signed out never connects from the tray', () async {
    final calls = <String>[];
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: calls, authenticated: false);
    await _startTray(container, platform);

    expect(
      platform.applied.single.entries.map((e) => e.action),
      isNot(contains(TrayAction.connect)),
    );
    // Even a stale dispatch is a no-op while signed out.
    platform.actionPicked!(TrayAction.connect);
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
  });

  test('an unavailable tray leaves close-to-quit alone', () async {
    final calls = <String>[];
    final platform = _FakeTrayPlatform(available: false);
    final container = await makeContainer(calls: calls);

    await _startTray(container, platform);
    await Future<void>.delayed(Duration.zero);

    expect(platform.applied, isEmpty);
    // No connection-side effects either: nothing was subscribed.
    expect(calls, isEmpty);
  });

  test('updateLabels rebuilds the menu with the new words', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);
    final tray = await _startTray(container, platform);
    final before = platform.applied.length;

    tray.updateLabels(
      const TrayLabels(
        tooltip: 'BoltMesh VPN',
        show: 'Anzeigen',
        hide: 'Ausblenden',
        connect: 'Verbinden',
        disconnect: 'Trennen',
        quit: 'Beenden',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(platform.applied.length, before + 1);
    expect(platform.applied.last.entries.last.label, 'Beenden');

    // Identical labels are a no-op (locale-only rebuilds stay cheap).
    tray.updateLabels(
      const TrayLabels(
        tooltip: 'BoltMesh VPN',
        show: 'Anzeigen',
        hide: 'Ausblenden',
        connect: 'Verbinden',
        disconnect: 'Trennen',
        quit: 'Beenden',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(platform.applied.length, before + 1);
  });

  test('dispose closes subscriptions and the platform', () async {
    final platform = _FakeTrayPlatform();
    final container = await makeContainer(calls: []);
    final tray = DesktopTray(
      container: container,
      platform: platform,
      labels: _labels,
    );
    await tray.start();
    await Future<void>.delayed(Duration.zero);

    await tray.dispose();

    expect(platform.disposed, 1);
  });
}
