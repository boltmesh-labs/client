import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/env.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Opens [uri] in the system browser.
///
/// Injectable so the widget test can observe the launch without a platform
/// channel; production passes the real `launchUrl`.
typedef WebsiteLauncher = Future<bool> Function(Uri uri);

Future<bool> _defaultLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// "Create account" affordance under the login form: a button that opens the
/// account-creation site, with the URL printed underneath as selectable text.
///
/// The URL is shown even though the button exists because the launch is not
/// guaranteed — a desktop without a registered browser handler, or a user
/// mid-sign-in who just wants the address — and copyable text is the fallback
/// when [WebsiteLauncher] returns false.
///
/// Renders nothing at all when [url] is empty, so a build without
/// `WEBSITE_URL` shows no dead affordance.
class CreateAccountLink extends StatelessWidget {
  const CreateAccountLink({super.key, required this.url, this.launcher});

  /// Site to open, expected to come from [Env.websiteUrl] (already validated).
  final String url;

  final WebsiteLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    // A build can pass anything through the define; re-check here so the row
    // and the launch agree on what is being offered.
    if (url.isEmpty || !isLaunchableWebUrl(url)) {
      return const SizedBox.shrink();
    }
    return _CreateAccountLinkBody(url: url, launcher: launcher);
  }
}

class _CreateAccountLinkBody extends StatelessWidget {
  const _CreateAccountLinkBody({required this.url, this.launcher});

  final String url;
  final WebsiteLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => _open(context),
          child: Text(l10n.loginCreateAccount),
        ),
        // Selectable so a failed launch still leaves the user with the
        // address in hand; the link above is the primary action.
        SelectableText(
          l10n.loginCreateAccountUrl(url),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final uri = Uri.parse(url);
    final launch = launcher ?? _defaultLauncher;
    bool opened = false;
    try {
      opened = await launch(uri);
    } catch (_) {
      // A missing browser handler surfaces as a PlatformException; the URL is
      // on screen either way, so this is a hint, not an error.
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.loginCreateAccountFailed)),
      );
    }
  }
}
