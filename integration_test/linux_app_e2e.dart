// End-to-end for the **Linux desktop app**: the real GUI signs in against the
// real API, connects through the real privileged `boltmeshd`, and the run
// passes only once a real WireGuard tunnel has carried bytes.
//
// `test/` cannot hold this. Everything there is deterministic and offline;
// this one needs a live serving node, real credentials, the installed helper
// and a display, so it is deliberately outside `flutter test` and is run by
// `tool/e2e/run_linux_app.sh` (Xvfb + an isolated keyring + the app's own
// `--dart-define`s). The daemon-level counterpart is `tool/e2e/run.sh`.
//
// The pass condition is deliberately the transport's, not the UI's: a run that
// reached `connected` with zero received bytes proves nothing, because a local
// address in the same namespace short-circuits routing (see tool/e2e/README).
// So it asserts on counters, on the kernel's own view, and on an in-tunnel
// ping, then tears the tunnel back down — this box is the client host, so a
// leftover full-tunnel would outlive the run.
//
// Credentials come from the environment, never from a checked-in file:
// BOLTMESH_E2E_API_USER / BOLTMESH_E2E_API_PASSWORD (same convention as
// tool/e2e/run.sh).
//
// The four tests run in order and build on each other: sign in, connect,
// switch server, log out. Each calls `app.main()` for a fresh widget tree,
// but the keyring persists across tests in a run, so the session is restored
// between them — which is itself the restore path being exercised.

library;

import 'dart:io';

import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/features/vpn/ui/home/power_button.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:boltmesh/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Sign-in is one HTTPS round trip against the real API, but the device
/// bind and the first WireGuard handshake are not fast. Generous on purpose:
/// a slow pass is fine, a flaky pass teaches nothing.
const _signInTimeout = Duration(seconds: 60);
const _connectTimeout = Duration(seconds: 120);
const _trafficTimeout = Duration(seconds: 60);

/// The interface `boltmeshd` names for the tunnel (`boltmeshd/README.md`).
const _tunnelInterface = 'boltmesh0';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signs in', (tester) async {
    await _launch(tester);
    await _ensureSignedIn(tester);
    await _shot('01-signed-in');
  });

  testWidgets('connects and moves real WireGuard bytes', (tester) async {
    await _launch(tester);
    final container = _container(tester);
    ConnState state() => container.read(connectionProvider);

    // The tunnel lives in the host namespace, not in this process, so a failed
    // run would otherwise leave the box full-tunnelled with no way back.
    addTearDown(_noTunnelLeftBehind);

    await _ensureSignedIn(tester);
    await _shot('02-home');

    // --- connect ---------------------------------------------------------
    await _connect(tester, state);
    await _shot('03-connected');

    // The UI has to agree with the state it renders: this is a GUI run, so a
    // controller that reached `connected` behind a stuck spinner would pass a
    // state-only assertion.
    final l10n = AppLocalizations.of(
      tester.element(find.byType(NavigationBar)),
    );
    expect(find.text(l10n.homeDisconnect), findsOneWidget);
    expect(find.textContaining(l10n.homeStatusConnected), findsWidgets);

    // --- bytes actually crossed the tunnel --------------------------------
    await _pumpUntil(
      tester,
      'received bytes to appear on the tunnel',
      () => (state().rxBytes ?? 0) > 0,
      timeout: _trafficTimeout,
      diagnose: state,
    );
    final received = state().rxBytes ?? 0;
    // ignore: avoid_print
    print('e2e: app reports rx=$received tx=${state().txBytes} bytes');

    // The kernel's own counters, when the kernel owns the data plane. On the
    // obfuscated rung the interface is a userspace AmneziaWG tun and `wg show`
    // reads nothing, which is not a failure — there the app's counters (read
    // from the helper) are the equivalent view, so it is reported either way.
    final kernelRx = await _kernelReceivedBytes();
    if (kernelRx == null) {
      // ignore: avoid_print
      print(
        'e2e: no kernel $_tunnelInterface device (userspace data plane); '
        'the app\'s counters above stand as the evidence',
      );
    } else {
      // ignore: avoid_print
      print('e2e: kernel $_tunnelInterface received $kernelRx bytes');
      expect(
        kernelRx,
        greaterThan(0),
        reason: 'the kernel device exists, so it must have moved bytes too',
      );
    }

    // --- an in-tunnel packet really gets there --------------------------
    final nodeTunnelIp = _nodeTunnelIp(state());
    expect(
      nodeTunnelIp,
      isNotNull,
      reason: 'the dial payload must carry the node\'s tunnel address',
    );
    final ping = await Process.run('ping', [
      '-c',
      '3',
      '-W',
      '3',
      nodeTunnelIp!,
    ]);
    // ignore: avoid_print
    print(
      'e2e: in-tunnel ping $nodeTunnelIp -> ${ping.exitCode}\n'
      '${(ping.stdout as String).trim()}',
    );
    expect(
      ping.exitCode,
      isZero,
      reason: 'the in-tunnel ping must succeed while connected',
    );
    expect((ping.stdout as String), contains('0% packet loss'));
    await _shot('04-tunnel-verified');

    // --- disconnect leaves the host as it was ----------------------------
    await tester.ensureVisible(_powerButton(tester));
    await tester.pumpAndSettle();
    await tester.tap(_powerButton(tester));
    await tester.pump();
    await _expectTunnelDown(tester, state);
    await _shot('05-disconnected');
  });

  testWidgets('switches server', (tester) async {
    await _launch(tester);
    final container = _container(tester);
    ConnState state() => container.read(connectionProvider);

    addTearDown(_noTunnelLeftBehind);

    await _ensureSignedIn(tester);

    // Connect first so there is a server to switch away from.
    await _connect(tester, state);
    final original = state().dial;
    expect(original?.serverName, isNotNull);
    // ignore: avoid_print
    print('e2e: connected to ${original!.serverName}');

    // --- switch to a different server via the Regions tab -----------------
    final l10n = AppLocalizations.of(
      tester.element(find.byType(NavigationBar)),
    );
    await tester.tap(find.text(l10n.navRegions));
    await tester.pump();
    await _pumpUntil(
      tester,
      'the regions list to load',
      () => find.byType(ExpansionTile).evaluate().isNotEmpty,
      timeout: _signInTimeout,
    );

    // Pick a server that is not the one the tunnel is actually on.
    //
    // `serverId` is the *pin*, which is null whenever the connect was an
    // unpinned Auto pick — comparing against it makes the live server look
    // like a valid target, and the run then reports "switching test1 to
    // test1". The live dial is the only thing that says where we are.
    final regions = container.read(regionsProvider).value ?? [];
    String? targetServerId;
    String? targetServerName;
    String? targetRegionName;
    for (final region in regions) {
      for (final server in region.servers) {
        if (server.id != original.serverId) {
          targetServerId = server.id;
          targetServerName = server.name;
          targetRegionName = region.name;
          break;
        }
      }
      if (targetServerId != null) break;
    }

    if (targetServerId == null) {
      // Only one server on offer, so there is nothing to switch *to*. Quick
      // Connect still exercises the other dial path (an unpinned re-pick) and
      // is worth asserting; it just cannot change the answer.
      // ignore: avoid_print
      print('e2e: only one server available; exercising Quick Connect instead');
      await tester.tap(find.text(l10n.regionsQuickConnect));
      await tester.pump();
      await _pumpUntil(
        tester,
        'Quick Connect to re-dial',
        () => state().phase == ConnPhase.connected,
        timeout: _connectTimeout,
        diagnose: state,
      );
    } else {
      // ignore: avoid_print
      print('e2e: switching ${original.serverName} -> $targetServerName');
      // The server rows live inside a collapsed ExpansionTile, so the region
      // has to be opened first — the rows are not in the tree until it is.
      final regionTile = find.ancestor(
        of: find.text(targetRegionName!),
        matching: find.byType(ExpansionTile),
      );
      expect(regionTile, findsOneWidget);
      await tester.tap(regionTile);
      await tester.pump();
      await _pumpUntil(
        tester,
        'the $targetRegionName servers to expand',
        () => find
            .descendant(
              of: regionTile,
              matching: find.widgetWithText(ListTile, targetServerName!),
            )
            .evaluate()
            .isNotEmpty,
        timeout: _signInTimeout,
      );
      final serverRow = find.descendant(
        of: regionTile,
        matching: find.widgetWithText(ListTile, targetServerName!),
      );
      // Settle before tapping, not just scroll: `ensureVisible` animates the
      // list and the ExpansionTile is still expanding its children, so a tap
      // issued straight afterwards aims at where the row *was*.
      await tester.ensureVisible(serverRow);
      await tester.pumpAndSettle();
      await tester.tap(serverRow);
      await tester.pump();

      await _pumpUntil(
        tester,
        'the tunnel to move to $targetServerName',
        () =>
            state().phase == ConnPhase.connected &&
            state().dial?.serverId == targetServerId,
        timeout: _connectTimeout,
        diagnose: state,
      );
    }
    await _shot('06-switched');

    expect(state().phase, ConnPhase.connected);
    // ignore: avoid_print
    print(
      'e2e: now on ${state().dial?.serverName} '
      '(was ${original.serverName}, pin=${state().serverId})',
    );

    // --- tear the switched tunnel back down ------------------------------
    // Not optional: this box *is* the client, so a tunnel left up here is a
    // full-tunnel that the next test would then connect through.
    final l10nBack = AppLocalizations.of(
      tester.element(find.byType(NavigationBar)),
    );
    await tester.tap(find.text(l10nBack.navConnect));
    await tester.pump();
    await _pumpUntil(
      tester,
      'the Connect tab to be showing again',
      () => _powerButton(tester).evaluate().isNotEmpty,
      timeout: _signInTimeout,
    );
    await tester.ensureVisible(_powerButton(tester));
    await tester.pumpAndSettle();
    await tester.tap(_powerButton(tester));
    await tester.pump();
    await _expectTunnelDown(tester, state);
  });

  testWidgets('logs out', (tester) async {
    await _launch(tester);
    final container = _container(tester);
    ConnState state() => container.read(connectionProvider);

    addTearDown(_noTunnelLeftBehind);

    await _ensureSignedIn(tester);

    // Connect first so logout has to tear down a live tunnel.
    await _connect(tester, state);

    // --- log out via the Settings tab -------------------------------------
    final l10n = AppLocalizations.of(
      tester.element(find.byType(NavigationBar)),
    );
    await tester.tap(find.text(l10n.navSettings));
    await tester.pump();
    await _pumpUntil(
      tester,
      'the settings screen',
      () => find.text(l10n.settingsLogOut).evaluate().isNotEmpty,
      timeout: _signInTimeout,
    );

    await tester.tap(find.text(l10n.settingsLogOut));
    await tester.pump();

    // The auth gate should flip back to the login screen.
    await _pumpUntil(
      tester,
      'the login screen',
      () =>
          find.byType(TextField).evaluate().isNotEmpty &&
          find.text(l10n.loginTitle).evaluate().isNotEmpty,
      timeout: _signInTimeout,
    );
    await _shot('07-logged-out');

    // The tunnel should be gone.
    expect(
      _interfaceExists(),
      isFalse,
      reason: 'logout must tear down the tunnel',
    );
    expect(state().phase, ConnPhase.idle);
  });
}

// --- helpers ---------------------------------------------------------------

/// Launches the app and returns once the first frame is drawn.
Future<void> _launch(WidgetTester tester) async {
  await app.main();
  await tester.pump(const Duration(milliseconds: 500));
}

/// The app's own ProviderContainer.
ProviderContainer _container(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(app.BoltMeshApp)),
    listen: false,
  );
}

/// Safety net for a test that died mid-tunnel.
///
/// Deliberately does *not* go through the app's controller: `addTearDown` runs
/// after the widget tree and its `ProviderContainer` are gone, so reading a
/// provider here throws "container already disposed" and the net accomplishes
/// nothing. It goes to the helper's socket instead, which is alive regardless
/// of app state — otherwise a failed test leaves a full-tunnel on the host and
/// every later test connects through a stale one.
Future<void> _noTunnelLeftBehind() async {
  if (!_interfaceExists()) return;
  final here = Directory.current.path;
  final client = '$here/tool/e2e/client.py';
  if (File(client).existsSync()) {
    await Process.run('python3', [
      client,
      '--socket',
      '/run/boltmesh/boltmeshd.sock',
      '--down',
    ]);
  }
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (_interfaceExists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (_interfaceExists()) {
    // ignore: avoid_print
    print(
      'WARNING: $_tunnelInterface is still up. Tear it down with:\n'
      '  sudo wg-quick down /run/boltmesh/wg$_tunnelInterface.conf || '
      'sudo ip link del $_tunnelInterface',
    );
  }
}

/// Asserts the tunnel is down and the interface is gone from the host.
Future<void> _expectTunnelDown(
  WidgetTester tester,
  ConnState Function() state,
) async {
  await _pumpUntil(
    tester,
    'the tunnel to go down',
    () => state().phase == ConnPhase.idle && !_interfaceExists(),
    timeout: _connectTimeout,
    diagnose: state,
  );
  expect(state().phase, ConnPhase.idle);
  expect(
    _interfaceExists(),
    isFalse,
    reason: '$_tunnelInterface must not outlive the session',
  );
}

/// The power button on the Home tab.
Finder _powerButton(WidgetTester tester) {
  return find.descendant(
    of: find.byType(PowerButton),
    matching: find.byType(FilledButton),
  );
}

/// Taps Connect and waits for the tunnel to be up.
///
/// Shared by the three tests that need a live tunnel.
///
/// Both waits are load-bearing, because each one's alternative failure is
/// silent rather than loud:
///
///  * **Scrolling into view.** The Home tab centers its content in a
///    `SingleChildScrollView`, and with the status header, the backend banner
///    and the 168px power button stacked, the button sits below the fold of a
///    default-height window. A tap on an off-screen widget lands on nothing.
///
///  * **Waiting for the button to be enabled.** Connect is hard-disabled while
///    the backend-health poll reports `unreachable`, which on a headless lab box
///    is a real possibility: `connectivity_plus` reads NetworkManager over
///    D-Bus, and a session without one reports no link. A tap on a disabled
///    button hit-tests cleanly and does nothing, so without this wait the run
///    would burn the whole connect timeout and then blame the transport.
Future<void> _connect(WidgetTester tester, ConnState Function() state) async {
  final power = _powerButton(tester);
  await _pumpUntil(
    tester,
    'the Home tab power control',
    () => power.evaluate().isNotEmpty,
    timeout: _signInTimeout,
  );

  try {
    await _pumpUntil(
      tester,
      'the Connect button to become enabled',
      () => tester.widget<FilledButton>(power).onPressed != null,
      timeout: _signInTimeout,
    );
  } on TestFailure {
    fail(
      'the Connect button stayed disabled for ${_signInTimeout.inSeconds}s, so '
      'the tap after this would be a no-op.\n'
      'This is the backend-health gate, which hard-disables Connect while '
      '`GET /health` is unreachable or the OS reports no network link. On a '
      'headless box `connectivity_plus` needs NetworkManager on the session '
      'bus; a session without one reads as "no link" and the app is right to '
      'refuse.\n'
      'last state: ${_describe(state())}',
    );
  }

  await tester.ensureVisible(power);
  await tester.pumpAndSettle();
  await tester.tap(power);
  await tester.pump();

  // Split the wait in two so a tap that never took effect is not reported as a
  // transport that never came up. `idle` -> anything else is the controller
  // accepting the request; only after that is the clock on the tunnel.
  await _pumpUntil(
    tester,
    'the tap to be picked up by the controller (phase to leave idle)',
    () => state().phase != ConnPhase.idle,
    timeout: const Duration(seconds: 30),
    diagnose: state,
  );

  await _pumpUntil(
    tester,
    'the tunnel to reach the connected phase',
    () => state().phase == ConnPhase.connected,
    timeout: _connectTimeout,
    diagnose: state,
  );
}

/// Ensures the app is signed in, signing in through the form if it has to.
///
/// Waits for the auth gate to *settle* before deciding, because the restore is
/// async: right after launch the screen is still the restoring spinner, so
/// neither the VPN tabs nor the form are mounted and a naive check would read
/// that as "signed out" and wait forever for a form that a restored session
/// was about to replace.
///
/// A stored session skips the form, and that is the session-restore path being
/// exercised rather than worked around. The runner script starts from a fresh
/// keyring, so a scripted run does drive the form itself.
Future<void> _ensureSignedIn(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    'the auth gate to settle',
    () =>
        find.byType(NavigationBar).evaluate().isNotEmpty ||
        find.byType(TextField).evaluate().isNotEmpty,
    timeout: _signInTimeout,
  );
  if (find.byType(NavigationBar).evaluate().isNotEmpty) {
    // ignore: avoid_print
    print('e2e: restored a stored session; skipping the sign-in form');
    return;
  }

  final user = _requireEnv('BOLTMESH_E2E_API_USER');
  final password = _requireEnv('BOLTMESH_E2E_API_PASSWORD');
  // Any widget under the app's MaterialApp carries the localization inherited
  // widget; the login screen's own Scaffold is the one mounted at this point.
  final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold).first));

  Finder fieldLabelled(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
    description: 'TextField labelled "$label"',
  );

  await _pumpUntil(
    tester,
    'the sign-in form',
    () => fieldLabelled(l10n.loginIdentifierLabel).evaluate().isNotEmpty,
    timeout: _signInTimeout,
  );

  await tester.enterText(fieldLabelled(l10n.loginIdentifierLabel), user);
  await tester.enterText(fieldLabelled(l10n.loginPasswordLabel), password);
  await tester.tap(find.widgetWithText(FilledButton, l10n.loginTitle));
  await tester.pump();

  try {
    await _pumpUntil(
      tester,
      'the VPN tabs',
      () => find.byType(NavigationBar).evaluate().isNotEmpty,
      timeout: _signInTimeout,
    );
  } on TestFailure catch (e) {
    // The form reports failures inline, so its own message is the diagnosis.
    // ignore: avoid_print
    print('e2e: sign-in did not reach the VPN tabs: $e');
    await _shot('signin-failed');
    rethrow;
  }
}

/// Pumps real frames until [done] holds, or fails with [diagnose] attached.
///
/// [WidgetTester.pump] in the live binding waits real time before drawing the
/// next frame, so this is the way to wait on real sockets and real WireGuard
/// here — `pumpAndSettle` would instead hang on the app's own polling timers.
Future<void> _pumpUntil(
  WidgetTester tester,
  String what,
  bool Function() done, {
  required Duration timeout,
  ConnState Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      final detail = diagnose?.call();
      fail(
        'timed out after ${timeout.inSeconds}s waiting for $what.'
        '${detail == null ? '' : '\nlast state: ${_describe(detail)}'}',
      );
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// One line of the controller's own view, so a failure names a cause instead
/// of only a phase.
String _describe(ConnState s) =>
    'phase=${s.phase.name} message="${s.message}" stage=${s.lastStage?.name} '
    'server=${s.dial?.serverName} endpoint=${s.dial?.endpoint}:${s.dial?.wgPort} '
    'rx=${s.rxBytes} tx=${s.txBytes} health="${s.healthNote ?? ''}" '
    'recovery=${s.recoveryAction?.name}/${s.recoveryReason?.name} '
    'opFailed=${s.opFailed}';

/// The node's address on the tunnel the client actually claimed.
///
/// The payload carries two: `wgDns` for the stock device and `awgDns` for the
/// obfuscated one. Which one is live is read off the interface the kernel was
/// given, because the node runs both devices in different networks and pinging
/// the wrong one is a "no route" that reads like a broken tunnel.
String? _nodeTunnelIp(ConnState s) {
  final dial = s.dial;
  if (dial == null) return null;
  final awg = dial.awgAssignedIp;
  if (awg != null && _interfaceHasAddress(awg)) return dial.awgDns;
  return dial.wgDns;
}

/// Bytes the kernel's own device received, or null when it has none (the
/// userspace obfuscated path, where `wg show` has nothing to read).
Future<int?> _kernelReceivedBytes() async {
  if (!_interfaceExists()) return null;
  final result = await Process.run('wg', [
    'show',
    _tunnelInterface,
    'transfer',
  ]);
  if (result.exitCode != 0) return null;
  final firstLine = '${result.stdout}'.trim().split('\n').first.trim();
  if (firstLine.isEmpty) return null;
  final fields = firstLine.split(RegExp(r'\s+'));
  // `transfer` prints "<peer>\t<received>\t<sent>"; this device has one peer.
  if (fields.length < 2) return null;
  return int.tryParse(fields[1]);
}

bool _interfaceExists() => _ipLink(['show', _tunnelInterface]).exitCode == 0;

bool _interfaceHasAddress(String address) {
  final result = _ipLink(['-4', '-o', 'addr', 'show', _tunnelInterface]);
  return result.exitCode == 0 && '${result.stdout}'.contains(address);
}

ProcessResult _ipLink(List<String> args) =>
    Process.runSync('ip', ['link', ...args]);

/// Screenshots of the real window, for a human to look at afterwards.
///
/// Best effort: ImageMagick's `import` is a lab convenience, not a
/// requirement, so its absence must not fail a run.
Future<void> _shot(String name) async {
  final dir = Platform.environment['BOLTMESH_E2E_SHOT_DIR'];
  if (dir == null || dir.isEmpty) return;
  await Directory(dir).create(recursive: true);
  final file = '$dir/$name.png';
  final result = await Process.run('import', [
    '-window',
    'root',
    '-silent',
    file,
  ]);
  // ignore: avoid_print
  print(
    result.exitCode == 0
        ? 'e2e: screenshot $file'
        : 'e2e: screenshot failed (${result.exitCode}): '
              '${(result.stderr as String).trim()}',
  );
}

String _requireEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    fail(
      '$name is not set. The staging credentials go through the environment, '
      'never a flag or a checked-in file; source tool/e2e/.env.e2e or export '
      'them before running this.',
    );
  }
  return value;
}
