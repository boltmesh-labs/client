import 'package:flutter/widget_previews.dart';
import 'package:flutter/widgets.dart';

import '../features/auth/ui/login_screen.dart';
import '../features/vpn/state/vpn_providers.dart';
import 'harness.dart';

@Preview(name: 'Login', group: 'BoltMesh')
Widget loginPreview() {
  return previewShell(
    connState: const ConnState(),
    authenticated: false,
    child: const LoginScreen(),
  );
}
