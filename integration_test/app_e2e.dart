// End-to-end for the **Linux, Windows and Android apps**: the real GUI signs in
// against the real API, brings up a real WireGuard tunnel, and the run passes
// only once that tunnel has carried bytes.
//
// `test/` cannot hold this. Everything there is deterministic and offline;
// this one needs a live serving node, real credentials, the tunnelling stack
// and a display, so it is deliberately outside `flutter test` and is driven by
// a runner script per platform (`tool/e2e/run_linux_app.sh` on Xvfb +
// isolated keyring, `tool/e2e/run_windows_app.ps1` in an interactive session,
// `tool/e2e/run_android_app.sh` against an attached emulator/device; all three
// pass the app's own `--dart-define`s).
//
// One program runs on all three: the app already carries its own platform seam
// (`createHelperSocket()` picks the Unix socket or the named pipe, over
// identical framing; Android has no helper at all and runs the data plane
// in-process), so what is left is the tunnel transport, the local tools a host
// happens to ship, and how a screenshot is taken — all of it collected in
// [_Host] below rather than sprinkled through the four tests.
//
// On Android the run is the app itself under `flutter test -d <device>`, so the
// credentials cannot come from the host's environment: `_requireEnv` reads the
// `--dart-define`s the runner passes instead. The independent "the tunnel
// exists" view is `NetworkInterface.list()`; Android has no `ip`/`wg` an
// unprivileged app may call and no privileged helper to ask.
//
// The pass condition is deliberately the transport's, not the UI's: a run that
// reached `connected` with zero received bytes proves nothing, because a local
// address in the same namespace short-circuits routing (see tool/e2e/README).
// So it asserts on counters, on the data plane's own view, and on an in-tunnel
// ping, then tears the tunnel back down — this box is the client host, so a
// leftover full-tunnel would outlive the run.
//
// Credentials come from the environment, never from a checked-in file:
// BOLTMESH_E2E_API_USER / BOLTMESH_E2E_API_PASSWORD.
//
// The four tests run in order and build on each other: sign in, walk the
// transport ladder up and back down (native, awg, stream, native), switch
// server, log out. Each calls `app.main()` for a fresh widget tree, but the
// keyring persists across tests in a run, so the session is restored between
// them — which is itself the restore path being exercised.
//
// The ladder walk drives the real controller through every rung with its
// `debugForceRung` seam: the controller starts on the node's floor and only
// demotes on health evidence a lab run cannot fabricate, so the seam is what
// lets one run prove all three data planes really carry bytes. It descends
// again on purpose: the rung change back *into* stock hands Android's single
// VpnService from the in-process AWG host to the stock plugin, which the
// upward walk never does.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/data/models.dart';
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

  testWidgets('walks the transport ladder native, awg, stream, native', (
    tester,
  ) async {
    await _launch(tester);
    final container = _container(tester);
    final ctl = container.read(connectionProvider.notifier);
    ConnState state() => container.read(connectionProvider);

    // The tunnel lives in the host namespace, not in this process, so a failed
    // run would otherwise leave the box full-tunnelled with no way back.
    addTearDown(_noTunnelLeftBehind);

    await _ensureSignedIn(tester);
    await _shot('02-home');

    final automaticLadder = !Platform.isAndroid;
    if (automaticLadder) {
      addTearDown(_host.clearEndpointBlocks);
    }

    // Android cannot install host firewall rules from its app uid, so it
    // retains the explicit rung walk. Desktop runs exercise the production
    // health/recovery path by blackholing each server UDP endpoint in turn.
    final ladder = automaticLadder
        ? const [TransportRung.native, TransportRung.awg, TransportRung.stream]
        : const [
            TransportRung.native,
            TransportRung.awg,
            TransportRung.stream,
            TransportRung.native,
          ];
    for (var i = 0; i < ladder.length; i++) {
      final rung = ladder[i];
      if (!automaticLadder) ctl.testHooks.forceRung = rung;

      // --- connect on this rung ------------------------------------------
      if (i == 0) {
        // The first rung comes up through the GUI, and is the one start that
        // binds the device's peer.
        await _connect(tester, state);
      } else if (!automaticLadder) {
        // A rung change is a restart, not a new device session. Reconnecting
        // through the controller reconciles the still-bound peer from `config`
        // (a read) and replaces the live tunnel locally, where a GUI
        // disconnect+connect would spend two more of the backend's shared
        // per-IP write budget on every rung.
        await _reconnect(tester, ctl, state);
      }
      if (automaticLadder && i > 0) {
        final previous = ladder[i - 1];
        final previousPort = state().dial!.transportFor(previous)!.port;
        await _host.setEndpointBlocked(
          state().dial!.endpoint,
          previousPort,
          true,
        );
        await _pumpUntil(
          tester,
          'automatic demotion to the ${rung.name} rung',
          () =>
              state().phase == ConnPhase.connected && ctl.transportRung == rung,
          timeout: const Duration(minutes: 5),
          diagnose: state,
        );
      }
      expect(ctl.transportRung, rung, reason: 'expected ${rung.name} rung');
      // ignore: avoid_print
      print('e2e: connected on the ${rung.name} rung');
      await _shot('03-connected-$i-${rung.name}');

      // The UI has to agree with the state it renders: this is a GUI run, so a
      // controller that reached `connected` behind a stuck spinner would pass a
      // state-only assertion.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(NavigationBar)),
      );
      expect(find.text(l10n.homeDisconnect), findsOneWidget);
      expect(find.textContaining(l10n.homeStatusConnected), findsWidgets);

      // One diagnostic read of the host's interface table while a tunnel is up.
      // It is what tells the down-check's `tunnelExists` it is looking at the
      // right name: a passing down-check alone cannot prove `tun0` is ever seen.
      if (i == 0) await _host.logTunnelInterfaces();

      // --- bytes actually crossed the tunnel ------------------------------
      await _pumpUntil(
        tester,
        'received bytes to appear on the ${rung.name} rung',
        () => (state().rxBytes ?? 0) > 0,
        timeout: _trafficTimeout,
        diagnose: state,
      );
      final received = state().rxBytes ?? 0;
      // ignore: avoid_print
      print(
        'e2e: ${rung.name} reports rx=$received tx=${state().txBytes} bytes',
      );

      // The data plane's own counters, when the host can read them. The
      // obfuscated rung is a userspace AmneziaWG tun, and even the kernel-owned
      // rungs are not always readable from this unprivileged process, so a
      // missing read is reported rather than failed: the app's counters (read
      // from the helper) are the equivalent evidence there.
      final planeRx = await _host.kernelReceivedBytes();
      if (planeRx == null) {
        // ignore: avoid_print
        print(
          'e2e: no host-side $_tunnelInterface counter view on ${rung.name}; '
          'the app\'s counters above stand as the evidence',
        );
      } else {
        // ignore: avoid_print
        print('e2e: host-side $_tunnelInterface received $planeRx bytes');
        expect(
          planeRx,
          greaterThan(0),
          reason: 'the data plane exists, so it must have moved bytes too',
        );
      }

      // --- an in-tunnel packet really gets there --------------------------
      // The node runs one device per rung in its own overlay, so the address to
      // ping follows the rung: the stock device answers `wgDns`, the obfuscated
      // one only `awgDns`.
      final nodeTunnelIp = _rungNodeIp(state(), rung);
      expect(
        nodeTunnelIp,
        isNotNull,
        reason: 'the dial payload must carry the node\'s ${rung.name} address',
      );
      final ping = await Process.run(
        _host.pingBinary,
        _host.pingArgs(nodeTunnelIp!),
      );
      // ignore: avoid_print
      print(
        'e2e: in-tunnel ping $nodeTunnelIp on ${rung.name} -> '
        '${ping.exitCode}\n'
        '${(ping.stdout as String).trim()}',
      );
      expect(
        ping.exitCode,
        isZero,
        reason: 'the in-tunnel ping must succeed on the ${rung.name} rung',
      );
      expect((ping.stdout as String), contains(_host.zeroLossMarker));
      await _shot('04-tunnel-verified-$i-${rung.name}');
    }

    if (automaticLadder) {
      await _host.clearEndpointBlocks();
      ctl.testHooks.forceRung = TransportRung.native;
      await _reconnect(tester, ctl, state);
      expect(ctl.transportRung, TransportRung.native);
      await _pumpUntil(
        tester,
        'native handoff traffic after automatic demotion',
        () => (state().rxBytes ?? 0) > 0,
        timeout: _trafficTimeout,
        diagnose: state,
      );
      final nativeIp = _rungNodeIp(state(), TransportRung.native);
      expect(nativeIp, isNotNull);
      final ping = await Process.run(
        _host.pingBinary,
        _host.pingArgs(nativeIp!),
      );
      expect(ping.exitCode, isZero, reason: 'native handoff ping must succeed');
      expect('${ping.stdout}', contains(_host.zeroLossMarker));
      await _shot('04-native-handoff');
    }

    // --- one GUI disconnect leaves the host as it was --------------------
    await tester.ensureVisible(_powerButton(tester));
    await tester.pumpAndSettle();
    await tester.tap(_powerButton(tester));
    await tester.pump();
    await _expectTunnelDown(tester, state);
    await _shot('05-disconnected');

    // Hand the ladder back to the advertised rule for the suites that follow.
    ctl.testHooks.forceRung = null;
  });

  testWidgets('switches server', (tester) async {
    await _launch(tester);
    final container = _container(tester);
    final ctl = container.read(connectionProvider.notifier);
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

    // --- the moved tunnel really carries traffic --------------------------
    // The wait above is satisfied by the controller's own arc — it raises
    // `connected` only once the daemon reports a new handshake — but a GUI run
    // should be able to say a packet reached the *new* server, which is what a
    // human would ask. Pinging the destination is the check; the byte counters
    // are not, because they can carry the previous server's total across a
    // restart. The address follows the rung the switch landed on, exactly as
    // the ladder's ping does.
    final movedIp = _rungNodeIp(state(), ctl.transportRung);
    expect(
      movedIp,
      isNotNull,
      reason: 'the switched dial must carry the node\'s address as well',
    );
    final movedPing = await Process.run(
      _host.pingBinary,
      _host.pingArgs(movedIp!),
    );
    // ignore: avoid_print
    print(
      'e2e: in-tunnel ping $movedIp after the switch -> ${movedPing.exitCode}\n'
      '${(movedPing.stdout as String).trim()}',
    );
    expect(
      movedPing.exitCode,
      isZero,
      reason: 'the switched tunnel must pass traffic to its new server',
    );
    expect((movedPing.stdout as String), contains(_host.zeroLossMarker));
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
      await _host.tunnelExists(),
      isFalse,
      reason: 'logout must tear down the tunnel',
    );
    expect(state().phase, ConnPhase.idle);
  });
}

// --- helpers ---------------------------------------------------------------

/// Everything the run needs from the host that is not the app.
///
/// The app already carries its own platform seam, so the four tests above do
/// not branch on the OS: only the tunnel transport, the local tools a host
/// happens to ship, and the way a screenshot is taken differ. Those live here
/// so one file covers every platform instead of three copies drifting apart.
sealed class _Host {
  const _Host();

  /// The host this run is on, selected once.
  static final _Host current = Platform.isWindows
      ? const _WindowsHost()
      : Platform.isAndroid
      ? const _AndroidHost()
      : const _LinuxHost();

  /// Interpreter that runs `tool/e2e/client.py`.
  ///
  /// Windows ships `python` and no `python3`; `BOLTMESH_E2E_PYTHON` overrides
  /// both for a host that names it otherwise (a pyenv shim, a `py -3` alias).
  String get python {
    final override = Platform.environment['BOLTMESH_E2E_PYTHON'];
    if (override != null && override.isNotEmpty) return override;
    return Platform.isWindows ? 'python' : 'python3';
  }

  /// `client.py`'s endpoint flag: the transport the helper listens on here,
  /// matching what the app itself dials.
  List<String> get helperArgs;

  /// True when this host's helper endpoint is there to answer, so a teardown
  /// attempt is worth making.
  bool get helperEndpointExists;

  /// Adds or removes a temporary outbound UDP block for the server endpoint.
  Future<void> setEndpointBlocked(String endpoint, int port, bool blocked);

  /// Removes every temporary endpoint block owned by this E2E harness.
  Future<void> clearEndpointBlocks();

  /// True when the tunnel is present on the host, read from the host's own
  /// view (the link table on Linux, the adapter table on Windows, the interface
  /// table on Android) rather than the daemon's: this is what "the box is clean
  /// again" means. Async because Android's only unprivileged read of it is
  /// `NetworkInterface.list()`.
  Future<bool> tunnelExists();

  /// Bytes the data plane itself reports, or null where the host has no such
  /// read (the userspace obfuscated tun, an unprivileged process that cannot
  /// open the device).
  Future<int?> kernelReceivedBytes();

  /// Logs the host's interface table once while a tunnel is up, best effort.
  ///
  /// A diagnostic, not an assertion: the desktop hosts deliberately tolerate a
  /// host that cannot read the tunnel by name, and Android's [tunnelExists] only
  /// has to bite on the *down* check — so this exists to answer, with evidence
  /// rather than a guess, whether the app's `tun0` is really what
  /// `NetworkInterface.list()` reports while connected. No-op where the host has
  /// no such read.
  Future<void> logTunnelInterfaces() async {}

  /// ping's arguments for [ip] on this host.
  List<String> pingArgs(String ip);

  /// The ping executable to run. The desktop hosts resolve `ping` from `PATH`;
  /// Android names the binary outright, so the run does not depend on the
  /// process `PATH` a sandboxed app happens to carry.
  String get pingBinary => 'ping';

  /// The substring ping prints when it lost nothing, in its own dialect.
  String get zeroLossMarker;

  /// Writes a screenshot of the real window to [path]. Best effort: it is a
  /// lab convenience, not a requirement, so a failure is reported and the run
  /// continues.
  Future<void> screenshot(String path);

  /// What an operator should run by hand for a tunnel the run left up.
  String get teardownHint;
}

/// The host this run is on. Read once per call site so the tests stay readable.
final _Host _host = _Host.current;

Future<void> _runFirewallHelper(List<String> args) async {
  final result = await Process.run('sudo', [
    '-n',
    '/usr/local/libexec/boltmesh-e2e-firewall',
    ...args,
  ]);
  if (result.exitCode != 0) {
    throw StateError('E2E firewall helper failed: ${result.stderr}');
  }
}

Future<void> _runWindowsFirewallHelper(List<String> args) async {
  final script = '${Directory.current.path}\\tool\\e2e\\firewall_windows.ps1';
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script,
    ...args,
  ]);
  if (result.exitCode != 0) {
    throw StateError('E2E firewall helper failed: ${result.stderr}');
  }
}

class _LinuxHost extends _Host {
  const _LinuxHost();

  @override
  List<String> get helperArgs => ['--socket', helperSocketPath];

  @override
  bool get helperEndpointExists =>
      FileSystemEntity.typeSync(helperSocketPath) !=
      FileSystemEntityType.notFound;

  @override
  Future<void> setEndpointBlocked(String endpoint, int port, bool blocked) =>
      _runFirewallHelper([blocked ? 'block' : 'unblock', endpoint, '$port']);

  @override
  Future<void> clearEndpointBlocks() => _runFirewallHelper(['clear']);

  @override
  Future<bool> tunnelExists() async =>
      Process.runSync('ip', ['link', 'show', _tunnelInterface]).exitCode == 0;

  @override
  Future<int?> kernelReceivedBytes() async {
    if (!await tunnelExists()) return null;
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

  @override
  List<String> pingArgs(String ip) => ['-c', '3', '-W', '3', ip];

  @override
  String get zeroLossMarker => '0% packet loss';

  @override
  Future<void> screenshot(String path) async {
    // ImageMagick's `import` reads the X display the app is on; see the
    // runner's Xvfb.
    final result = await Process.run('import', [
      '-window',
      'root',
      '-silent',
      path,
    ]);
    await _reportShot(result, path);
  }

  @override
  String get teardownHint =>
      'sudo wg-quick down /run/boltmesh/wg$_tunnelInterface.conf || '
      'sudo ip link del $_tunnelInterface';
}

class _WindowsHost extends _Host {
  const _WindowsHost();

  @override
  List<String> get helperArgs => ['--pipe', helperPipePath];

  @override
  bool get helperEndpointExists =>
      Process.runSync('sc.exe', ['query', 'boltmeshd']).exitCode == 0;

  @override
  Future<void> setEndpointBlocked(String endpoint, int port, bool blocked) =>
      _runWindowsFirewallHelper([
        blocked ? 'block' : 'unblock',
        endpoint,
        '$port',
      ]);

  @override
  Future<void> clearEndpointBlocks() => _runWindowsFirewallHelper(['clear']);

  @override
  Future<bool> tunnelExists() async {
    // The adapter table, not the SCM: the obfuscated rung runs an in-process
    // AmneziaWG device over a Wintun adapter and registers no `boltmesh0`
    // service, so a service probe would read "no tunnel" mid-ladder. The
    // adapter is named `boltmesh0` on every rung, which is what makes this the
    // Windows analogue of `ip link show boltmesh0`.
    final result = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      'if (Get-NetAdapter -Name \'$_tunnelInterface\' -ErrorAction '
          'SilentlyContinue) { \'UP\' } else { \'DOWN\' }',
    ]);
    return result.exitCode == 0 && '${result.stdout}'.contains('UP');
  }

  @override
  Future<int?> kernelReceivedBytes() async {
    // There is no `wg show` on Windows, and the obfuscated rung's Wintun
    // device has no kernel counters at all: what the daemon reports is whatever
    // the data plane it owns says — read through wireguard.dll on the native
    // rung, and the device's own UAPI dump on the obfuscated one. So these are
    // the same numbers as the app's counters, read by a second, non-Flutter
    // client over the production transport. That is worth having (it is what
    // exercises `client.py --pipe` against the real daemon, and it fails
    // loudly when the daemon cannot read the device at all), but it is not the
    // independent kernel view the Linux line is.
    final status = await _daemonStatus();
    final rx = status?['rxBytes'];
    return rx is int ? rx : null;
  }

  @override
  List<String> pingArgs(String ip) => ['-n', '3', '-w', '3000', ip];

  @override
  String get zeroLossMarker => '(0% loss)';

  @override
  Future<void> screenshot(String path) async {
    // No X display and no ImageMagick on a stock Windows box: capture the
    // primary screen, which is where the app's window is.
    //
    // `-ExecutionPolicy Bypass` because a default box is often Restricted,
    // which refuses to load a script file at all — `-File` is what the policy
    // governs, not `-Command`, so the probes above are unaffected.
    final here = Directory.current.path;
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '$here/tool/e2e/screenshot.ps1',
      '-Path',
      path,
    ]);
    await _reportShot(result, path);
  }

  @override
  String get teardownHint =>
      'run boltmeshd.exe -cleanup from an elevated shell (it stops and removes '
      'the \$boltmesh0 tunnel)';
}

/// The Android host: the app *is* the tunnel.
///
/// There is no privileged helper, and none of the desktop probes work here —
/// `ip`, `wg` and `/proc/net/dev` are all denied to the app uid. So the host
/// view is Dart's own interface table: the `VpnService` TUN the app owns is
/// visible to it, which is the analogue of `ip link show`. The data plane is
/// in-process, so there is no second counters reader either and the app's own
/// counters stand alone. `client.py` teardown is correctly unreachable from
/// here (no helper endpoint, and the script is not on the device): a leftover
/// tunnel dies with the app process rather than following the box the way a
/// desktop helper's full-tunnel would.
class _AndroidHost extends _Host {
  const _AndroidHost();

  /// Matches the OS interface a `VpnService` TUN gets. `boltmesh0` is only the
  /// app's logical tunnel name; the kernel interface is `tun0`, and a one-VPN
  /// app only ever owns one. The digit is load-bearing: `tunl0` is the kernel's
  /// default IPIP interface and is present on a stock device, so a bare `tun`
  /// prefix would read it as a live tunnel forever and the down-check would
  /// never settle.
  static final _tunName = RegExp(r'^tun\d');

  @override
  List<String> get helperArgs => const [];

  @override
  bool get helperEndpointExists => false;

  @override
  Future<void> setEndpointBlocked(String endpoint, int port, bool blocked) =>
      throw UnsupportedError(
        'Android E2E does not control host firewall rules',
      );

  @override
  Future<void> clearEndpointBlocks() async {}

  @override
  Future<bool> tunnelExists() async {
    try {
      for (final iface in await NetworkInterface.list()) {
        if (_tunName.hasMatch(iface.name)) return true;
      }
    } on SocketException {
      // An interface table this process cannot read is "unknown", and every
      // caller uses this only to confirm a tunnel is *gone*. Reporting "gone"
      // on an unreadable table cannot leave a live tunnel behind, so fall
      // through to false and let the controller-state assertions carry it.
    }
    return false;
  }

  @override
  Future<int?> kernelReceivedBytes() async => null;

  @override
  Future<void> logTunnelInterfaces() async {
    try {
      final names = [
        for (final iface in await NetworkInterface.list()) iface.name,
      ];
      // ignore: avoid_print
      print('e2e: Android interface table while connected: $names');
    } on SocketException catch (e) {
      // ignore: avoid_print
      print('e2e: Android interface table unreadable ($e)');
    }
  }

  @override
  List<String> pingArgs(String ip) => ['-c', '3', '-W', '3', ip];

  @override
  String get pingBinary => '/system/bin/ping';

  @override
  String get zeroLossMarker => '0% packet loss';

  @override
  Future<void> screenshot(String path) async {
    // A picture of the device screen belongs to the host, not the app: the
    // test cannot reach `screencap` and hand the file to the runner, so an
    // Android run takes none. Best effort by contract, so this is not a
    // failure — the host can grab one with `adb exec-out screencap -p` if it
    // wants one.
    // ignore: avoid_print
    print('e2e: screenshots are not captured in an Android run (path $path)');
  }

  @override
  String get teardownHint =>
      'adb shell am force-stop com.boltmesh.boltmesh (the VpnService dies with '
      'the app process)';
}

/// The daemon's own view of the tunnel, read through `client.py` so the
/// teardown and status reads survive the widget tree being gone.
Future<Map<String, dynamic>?> _daemonStatus() async {
  final here = Directory.current.path;
  final client = '$here/tool/e2e/client.py';
  if (!File(client).existsSync()) return null;
  final result = await Process.run(_host.python, [
    client,
    ..._host.helperArgs,
    '--status',
  ]);
  if (result.exitCode != 0) return null;
  final decoded = jsonDecode('${result.stdout}');
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// Reports one screenshot attempt, whatever came of it.
Future<void> _reportShot(ProcessResult result, String path) async {
  // ignore: avoid_print
  print(
    result.exitCode == 0
        ? 'e2e: screenshot $path'
        : 'e2e: screenshot failed (${result.exitCode}): '
              '${(result.stderr as String).trim()}',
  );
}

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
/// nothing. It goes to the helper's transport instead, which is alive
/// regardless of app state — otherwise a failed test leaves a full-tunnel on
/// the host and every later test connects through a stale one.
Future<void> _noTunnelLeftBehind() async {
  final here = Directory.current.path;
  final client = '$here/tool/e2e/client.py';
  // Not gated on `tunnelExists()`. On a host where the test cannot see the
  // tunnel by name, that gate would skip the teardown exactly when a failed
  // run needs it, leaving a live full-tunnel for the next suite. A `down`
  // with nothing up is what the helper already tolerates.
  if (File(client).existsSync() && _host.helperEndpointExists) {
    await Process.run(_host.python, [client, ..._host.helperArgs, '--down']);
  }
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (await _host.tunnelExists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (await _host.tunnelExists()) {
    // ignore: avoid_print
    print(
      'WARNING: $_tunnelInterface is still up. Tear it down with:\n'
      '  ${_host.teardownHint}',
    );
  }
}

/// Asserts the tunnel is down and gone from the host.
Future<void> _expectTunnelDown(
  WidgetTester tester,
  ConnState Function() state,
) async {
  await _pumpUntilAsync(
    tester,
    'the tunnel to go down',
    () async => state().phase == ConnPhase.idle && !await _host.tunnelExists(),
    timeout: _connectTimeout,
    diagnose: state,
  );
  expect(state().phase, ConnPhase.idle);
  expect(
    await _host.tunnelExists(),
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
///    D-Bus on Linux, and a session without one reports no link. A tap on a
///    disabled button hit-tests cleanly and does nothing, so without this wait
///    the run would burn the whole connect timeout and then blame the
///    transport.
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

/// Reconnects the live tunnel onto the currently forced rung.
///
/// Used for the ladder's second and later rungs: a rung change is a restart of
/// the same device session, so `connect()` reconciles the still-bound peer from
/// `config` (a read) and `_startWith` replaces the tunnel locally. A GUI
/// disconnect+connect per rung would instead spend two more of the backend's
/// shared per-IP write budget each time, which the walk cannot afford.
///
/// The wait is on the connect *future*, not on the phase leaving `connected`.
/// The controller does raise `working` at the top of its connect, but a warm
/// rung change runs that whole arc — config, tunnel start, LAN handshake and
/// back to `connected` — inside one 200ms poll, so a sampled dip is a race: it
/// held on a cold box and timed out on a warm one. The future completes exactly
/// when the restart has run to completion, which is what this needs to know.
Future<void> _reconnect(
  WidgetTester tester,
  ConnectionController ctl,
  ConnState Function() state,
) async {
  final restarted = ctl.connect();
  // Keep frames coming while the restart runs — the app schedules its own work
  // per frame — but let the future be the signal. `await restarted` at the end
  // is what surfaces a failure; this subscription only reports completion.
  final finished = Completer<void>();
  unawaited(
    restarted.then(
      (_) => finished.complete(),
      onError: (Object _) => finished.complete(),
    ),
  );
  await _pumpUntil(
    tester,
    'the restart to run to completion',
    () => finished.isCompleted,
    timeout: _connectTimeout,
    diagnose: state,
  );
  await restarted;
  // A connect that failed without throwing lands in `error`; this turns that
  // into the phase assertion below rather than a puzzling ping failure.
  await _pumpUntil(
    tester,
    'the tunnel to report connected on the new rung',
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
/// exercised rather than worked around. Each runner script starts from a fresh
/// store (a scratch keyring on Linux, no secure-storage file on Windows), so a
/// scripted run does drive the form itself.
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

/// [_pumpUntil] for a condition that itself has to await.
///
/// Android's tunnel probe is `NetworkInterface.list()`, which is asynchronous,
/// so the down-check in [_expectTunnelDown] cannot be a plain `bool Function()`.
/// The clock and the failure reporting are the same as [_pumpUntil]'s on
/// purpose.
Future<void> _pumpUntilAsync(
  WidgetTester tester,
  String what,
  Future<bool> Function() done, {
  required Duration timeout,
  ConnState Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await done()) {
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

/// The node's address on the tunnel [rung] actually claimed.
///
/// The node runs one device per rung in its own overlay, so which address is
/// reachable follows the rung: the stock device answers `wgDns`, the obfuscated
/// one only `awgDns`. Pinging the wrong one is a "no route" that reads like a
/// broken tunnel.
String? _rungNodeIp(ConnState s, TransportRung rung) {
  final dial = s.dial;
  if (dial == null) return null;
  return rung == TransportRung.awg ? dial.awgDns : dial.wgDns;
}

/// Screenshots of the real window, for a human to look at afterwards.
///
/// Best effort: the tool that takes them is a lab convenience, not a
/// requirement, so its absence must not fail a run.
Future<void> _shot(String name) async {
  final dir = Platform.environment['BOLTMESH_E2E_SHOT_DIR'];
  if (dir == null || dir.isEmpty) return;
  await Directory(dir).create(recursive: true);
  await _host.screenshot('$dir/$name.png');
}

String _requireEnv(String name) {
  final value = switch (name) {
    'BOLTMESH_E2E_API_USER' => _envOrDefine(name, _defineApiUser),
    'BOLTMESH_E2E_API_PASSWORD' => _envOrDefine(name, _defineApiPassword),
    _ => Platform.environment[name],
  };
  if (value == null || value.isEmpty) {
    fail(
      '$name is not set. The staging credentials go through the environment or '
      'the runner\'s --dart-defines, never a flag or a checked-in file; export '
      'them, or run this through tool/e2e/run_linux_app.sh, '
      'run_windows_app.ps1 or run_android_app.sh, which load .env.e2e '
      'automatically.',
    );
  }
  return value;
}

/// The staging credentials as compile-time `--dart-define`s.
///
/// A desktop run hands the credentials to the test process through the
/// environment, but an Android run *is* the app: the test code executes on the
/// device, where the host's environment does not exist. There the runner passes
/// them with `--dart-define-from-file`, which embeds them in the debug APK on
/// the emulator — the price of a credential the on-device process can read, and
/// the same trade the Windows relaunch makes with its work-directory file.
const _defineApiUser = String.fromEnvironment('BOLTMESH_E2E_API_USER');
const _defineApiPassword = String.fromEnvironment('BOLTMESH_E2E_API_PASSWORD');

/// The environment first, then the compile-time define; empty counts as unset.
String? _envOrDefine(String name, String define) {
  final fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return define.isEmpty ? null : define;
}
