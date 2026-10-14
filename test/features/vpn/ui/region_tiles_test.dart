import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/ui/regions/region_tiles.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('expanded server rows show name and load, not endpoint details', (
    tester,
  ) async {
    String? selectedServerId;
    const region = Region(
      id: 'de',
      name: 'Germany',
      servers: [
        DiscoveryServer(
          id: 'fra-1',
          name: 'Frankfurt 1',
          endpoint: 'fra-1.example.test',
          wgPort: 51820,
          activePeers: 2,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RegionExpansionTile(
            region: region,
            load: 2,
            busy: false,
            selectedServerId: 'fra-1',
            onServerTap: (id) => selectedServerId = id,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Germany'));
    await tester.pumpAndSettle();

    expect(find.text('Frankfurt 1'), findsOneWidget);
    expect(find.text('2 peers'), findsOneWidget);
    expect(find.textContaining('fra-1.example.test'), findsNothing);
    expect(find.textContaining('51820'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Frankfurt 1'));
    expect(selectedServerId, 'fra-1');
  });
}
