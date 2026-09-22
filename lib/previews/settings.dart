import 'package:flutter/widget_previews.dart';
import 'package:flutter/widgets.dart';

import '../features/vpn/state/vpn_providers.dart';
import '../features/vpn/ui/settings_screen.dart';
import 'harness.dart';

@Preview(name: 'Settings', group: 'BoltMesh')
Widget settingsPreview() {
  return previewShell(
    connState: const ConnState(),
    child: const SettingsScreen(),
  );
}
