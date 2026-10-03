import 'package:boltmesh/features/vpn/domain/backend_issue.dart';
import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/features/vpn/ui/home/health_banner.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns a fixed [ConnState] so the banner renders one slice in isolation.
class _FixedConnectionController extends ConnectionController {
  _FixedConnectionController(this._state);

  final ConnState _state;

  @override
  ConnState build() => _state;
}

Future<void> pumpBanner(WidgetTester tester, ConnState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _FixedConnectionController(state),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HealthBanner()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders nothing when healthy', (tester) async {
    await pumpBanner(tester, const ConnState(phase: ConnPhase.connected));
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('a healthNote wins over the structured issue', (tester) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.connected,
        healthNote: 'Backend unreachable (3×). Tunnel may be stale.',
        backendIssue: BackendIssue.unreachable,
      ),
    );
    expect(
      find.text('Backend unreachable (3×). Tunnel may be stale.'),
      findsOneWidget,
    );
  });

  testWidgets('a working transport recovery is localized', (tester) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.working,
        healthNote: 'raw diagnostic detail',
        recoveryAction: RecoveryAction.tryingStream,
        recoveryReason: RecoveryReason.staleHandshake,
      ),
    );
    expect(
      find.text('Trying the TLS stream: the peer handshake is stale'),
      findsOneWidget,
    );
    expect(find.text('raw diagnostic detail'), findsNothing);
  });

  testWidgets('server movement is distinct from a tunnel restart', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.working,
        recoveryAction: RecoveryAction.switchingServer,
        recoveryReason: RecoveryReason.serverOffline,
      ),
    );
    expect(
      find.text(
        'Switching to another server: the backend reports this server offline',
      ),
      findsOneWidget,
    );
  });

  testWidgets('authentication errors remain more important than recovery', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.working,
        recoveryAction: RecoveryAction.restarting,
        recoveryReason: RecoveryReason.staleHandshake,
        backendIssue: BackendIssue.authExpired,
      ),
    );
    expect(
      find.text('Session expired. Log in again to reconnect.'),
      findsOneWidget,
    );
  });

  testWidgets('authExpired renders the session copy, not a network error', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.connected,
        backendIssue: BackendIssue.authExpired,
      ),
    );
    expect(
      find.text('Session expired. Log in again to reconnect.'),
      findsOneWidget,
    );
    expect(find.textContaining('Backend unreachable'), findsNothing);
  });

  testWidgets('subscriptionInactive renders the renewal copy', (tester) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.connected,
        backendIssue: BackendIssue.subscriptionInactive,
      ),
    );
    expect(
      find.text('No active subscription. Renew to reconnect.'),
      findsOneWidget,
    );
  });

  testWidgets('unreachable without a note renders the connected copy', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      const ConnState(
        phase: ConnPhase.connected,
        backendIssue: BackendIssue.unreachable,
      ),
    );
    expect(
      find.text(
        'Backend unreachable. The tunnel stays up while recovery is attempted.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the banner is hidden while not connected', (tester) async {
    await pumpBanner(
      tester,
      const ConnState(backendIssue: BackendIssue.authExpired),
    );
    expect(find.byType(Card), findsNothing);
  });
}
