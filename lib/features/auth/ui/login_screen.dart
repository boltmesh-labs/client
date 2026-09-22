import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../state/auth_providers.dart';

/// Sign-in form. On success the auth gate switches to the VPN tabs
/// automatically; failures surface inline via [AuthState.error].
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (ref.read(authProvider).value?.working ?? false) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    FocusScope.of(context).unfocus();
    if (_identifier.text.trim().isEmpty || _password.text.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.loginValidationEmpty)),
      );
      return;
    }
    await ref
        .read(authProvider.notifier)
        .login(identifier: _identifier.text, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value ?? const AuthState();
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.vpn_lock, size: 64),
                const SizedBox(height: 16),
                Text(
                  l10n.loginTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _identifier,
                  decoration: InputDecoration(
                    labelText: l10n.loginIdentifierLabel,
                    hintText: l10n.loginIdentifierHint,
                    prefixIcon: const Icon(Icons.person),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  decoration: InputDecoration(
                    labelText: l10n.loginPasswordLabel,
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      tooltip: _showPassword
                          ? l10n.loginHidePassword
                          : l10n.loginShowPassword,
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  obscureText: !_showPassword,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 4),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      auth.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: auth.working ? null : _submit,
                  child: auth.working
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.loginTitle),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        l10n.loginOr,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: auth.working
                      ? null
                      : () => ref
                            .read(authProvider.notifier)
                            .signInWithProvider('google'),
                  icon: const Icon(Icons.g_mobiledata),
                  label: Text(l10n.loginGoogle),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: auth.working
                      ? null
                      : () => ref
                            .read(authProvider.notifier)
                            .signInWithProvider('github'),
                  icon: const Icon(Icons.code),
                  label: Text(l10n.loginGithub),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
