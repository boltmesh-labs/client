import 'package:boltmesh/features/vpn/data/device_store.dart';
import 'package:boltmesh/features/vpn/ui/settings/device_name_section.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fakes.dart' as support;

Future<void> pumpSection(
  WidgetTester tester,
  support.FakeDeviceStore store,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [deviceStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DeviceNameSection()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a name over the backend limit is rejected, not saved', (
    tester,
  ) async {
    final store = support.FakeDeviceStore();
    await pumpSection(tester, store);

    // 64 grapheme clusters but 128 code points: the field's grapheme-based
    // maxLength admits it, while the backend (and the store) counts code
    // points. It must be rejected instead of saved and then 422 on every
    // provision.
    await tester.enterText(
      find.byType(TextField),
      '\u0061\u0301' * maxDeviceNameLength,
    );
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(find.textContaining('or fewer'), findsOneWidget);
    expect(await store.deviceName(), isNull);
  });

  testWidgets('a valid name is saved', (tester) async {
    final store = support.FakeDeviceStore();
    await pumpSection(tester, store);

    await tester.enterText(find.byType(TextField), 'My Phone');
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(find.text('Device name saved'), findsOneWidget);
    expect(await store.deviceName(), 'My Phone');
  });
}
