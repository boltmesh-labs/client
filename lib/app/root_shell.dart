import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../features/auth/state/auth_providers.dart';
import '../features/auth/ui/login_screen.dart';
import 'authed_shell.dart';

/// Auth gate: the session restore runs in [AuthController.build], so while
/// the provider is loading only a spinner mounts. The VPN tabs (and their
/// provisioning/discovery) mount only under `authenticated`, never racing
/// the restore.
class RootShell extends ConsumerWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return auth.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      // Restore catches storage failures itself; an unexpected async error
      // still lands on the login screen instead of stranding the user, but is
      // logged so it isn't silently swallowed.
      error: (Object err, StackTrace stack) {
        AppLog.error('auth gate error', err);
        return const LoginScreen();
      },
      data: (s) => switch (s.status) {
        AuthStatus.unauthenticated => const LoginScreen(),
        AuthStatus.authenticated => const AuthedShell(),
      },
    );
  }
}
