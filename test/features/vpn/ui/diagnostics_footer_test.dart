import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/features/vpn/ui/settings/diagnostics_footer.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedConnectionController extends ConnectionController {
  _FixedConnectionController(this._state);

  final ConnState _state;

  @override
  ConnState build() => _state;
}

void main() {
  testWidgets('debug diagnostics expose structured recovery evidence', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(
            () => _FixedConnectionController(
              const ConnState(
                phase: ConnPhase.connected,
                recoveryAction: RecoveryAction.tryingStream,
                recoveryReason: RecoveryReason.staleHandshake,
                recoveryDetail: 'handshake stale (159s), echo dead ×2',
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DiagnosticsFooter()),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text(
        'Recovery: tryingStream · staleHandshake · '
        'handshake stale (159s), echo dead ×2',
      ),
      findsOneWidget,
    );
  });
}
