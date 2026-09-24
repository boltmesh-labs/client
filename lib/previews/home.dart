import 'package:flutter/widget_previews.dart';
import 'package:flutter/widgets.dart';

import '../features/vpn/data/models.dart';
import '../features/vpn/state/vpn_providers.dart';
import '../features/vpn/ui/home_screen.dart';
import 'fixtures.dart';
import 'harness.dart';

@Preview(name: 'Home disconnected', group: 'BoltMesh')
Widget homeDisconnectedPreview() {
  return previewShell(connState: const ConnState(), child: const HomeScreen());
}

@Preview(name: 'Home connected', group: 'BoltMesh')
Widget homeConnectedPreview() {
  return previewShell(
    connState: const ConnState(
      phase: ConnPhase.connected,
      dial: previewDial,
      regionId: 'r-fra',
      deviceStatus: DeviceStatus(
        deviceId: 'dev-preview',
        status: 'active',
        tier: 'Pro',
        maxDevices: 5,
        activeDevices: 1,
      ),
    ),
    child: const HomeScreen(),
  );
}

@Preview(name: 'Home error', group: 'BoltMesh')
Widget homeErrorPreview() {
  return previewShell(
    connState: const ConnState(
      phase: ConnPhase.error,
      message: 'Connection failed (preview).',
    ),
    child: const HomeScreen(),
  );
}
