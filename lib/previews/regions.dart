import 'package:flutter/widget_previews.dart';
import 'package:flutter/widgets.dart';

import '../features/vpn/state/vpn_providers.dart';
import '../features/vpn/ui/regions_screen.dart';
import 'fixtures.dart';
import 'harness.dart';

@Preview(name: 'Regions', group: 'BoltMesh')
Widget regionsPreview() {
  return previewShell(
    connState: const ConnState(),
    regions: previewRegions,
    child: const RegionsScreen(),
  );
}
