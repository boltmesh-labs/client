import 'package:boltmesh/features/vpn/state/vpn_providers.dart';
import 'package:boltmesh/features/vpn/ui/regions/switch_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> trigger(WidgetTester tester, ConnState state) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSwitchFeedback(context, state),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  testWidgets('snacks a failed switch that kept the old tunnel', (
    tester,
  ) async {
    await trigger(
      tester,
      const ConnState(
        phase: ConnPhase.connected,
        message: 'Switch failed, still on one.',
        opFailed: true,
      ),
    );
    expect(find.text('Switch failed, still on one.'), findsOneWidget);
  });

  testWidgets('snacks an errored operation', (tester) async {
    await trigger(
      tester,
      const ConnState(
        phase: ConnPhase.error,
        message: 'No servers available right now.',
      ),
    );
    expect(find.text('No servers available right now.'), findsOneWidget);
  });

  testWidgets('stays silent on a benign same-target no-op', (tester) async {
    await trigger(
      tester,
      const ConnState(phase: ConnPhase.connected, message: 'Already on one.'),
    );
    expect(find.text('Already on one.'), findsNothing);
  });
}
