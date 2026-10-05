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

  testWidgets('signs in, connects, and moves real WireGuard bytes', (
    tester,
  ) async {
    final user = _requireEnv('BOLTMESH_E2E_API_USER');
    final password = _requireEnv('BOLTMESH_E2E_API_PASSWORD');

    await app.main();
    await tester.pump(const Duration(milliseconds: 500));

    // The app's own container: main() builds the ProviderScope, so this is
    // the same state the widgets render from, not a parallel test double.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(app.BoltMeshApp)),
      listen: false,
    );
    ConnState state() => container.read(connectionProvider);

    // The tunnel lives in the host namespace, not in this process, so a failed
    // run would otherwise leave the box full-tunnelled with no way back.
    addTearDown(() async {
      await _disconnect(container);
      if (_interfaceExists()) {
        // ignore: avoid_print
        print(
          'WARNING: $_tunnelInterface is still up after this run. Tear it down '
          'with:\n'
          '  sudo wg-quick down /run/boltmesh/wg$_tunnelInterface.conf || '
          'sudo ip link del $_tunnelInterface',
        );
      }
    });

    await _signIn(tester, user, password);
    await _shot('02-home');

    // --- connect ---------------------------------------------------------
    final power = find.descendant(
      of: find.byType(PowerButton),
      matching: find.byType(FilledButton),
    );
    expect(
      power,
      findsOneWidget,
      reason:
          'the Home tab must offer the power '
          'control',
    );
    await tester.tap(power);
    await tester.pump();

    await _pumpUntil(
      tester,
      'the tunnel to reach the connected phase',
      () => state().phase == ConnPhase.connected,
      timeout: _connectTimeout,
      diagnose: state,
    );
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
    await tester.tap(power);
    await tester.pump();
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
    await _shot('05-disconnected');
  });
}

/// Signs in, unless a stored session already restored one.
///
/// The session lives in the OS keyring, so on a reused e2e keyring the app
/// comes up authenticated and this step is skipped — which is itself the
/// session-restore path being exercised rather than worked around.
Future<void> _signIn(WidgetTester tester, String user, String password) async {
  if (find.byType(NavigationBar).evaluate().isNotEmpty) {
    // ignore: avoid_print
    print('e2e: restored a stored session; skipping the sign-in form');
    return;
  }
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
  await _shot('01-signed-in');
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

/// Asks the controller, then waits for the interface to actually go away.
///
/// Best effort by design: this runs in the app's isolate after the widgets are
/// gone, so it goes straight to the controller rather than through a button.
Future<void> _disconnect(ProviderContainer container) async {
  // Already down: the test's own disconnect landed, and the container died with
  // the widget tree. Skipping beats printing a disposed-container error on
  // every passing run.
  if (!_interfaceExists()) return;
  try {
    await container.read(connectionProvider.notifier).disconnect();
  } catch (e) {
    // ignore: avoid_print
    print('e2e: disconnect through the controller failed: $e');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (_interfaceExists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

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
