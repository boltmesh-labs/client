import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/desktop/tray_manager_platform.dart';
import '../core/desktop/tray_menu.dart';
import '../core/desktop/tray_platform.dart';
import '../core/log.dart';
import '../features/auth/state/auth_providers.dart';
import '../features/vpn/state/vpn_providers.dart';
import '../l10n/gen/app_localizations.dart';

/// Desktop tray lifecycle: builds the menu from app state, routes tray actions
/// back into the connection controller, and turns the window's close button
/// into hide-to-tray.
///
/// Lives outside the widget tree (like [ResumeCoordinator]) so the wiring is
/// explicit and testable against a fake [TrayPlatform]; [DesktopTrayHost] only
/// owns construction (it needs the app locale) and disposal.
class DesktopTray {
  DesktopTray({
    required this._container,
    required this._platform,
    required this._labels,
  });

  final ProviderContainer _container;
  final TrayPlatform _platform;
  TrayLabels _labels;

  final _subs = <ProviderSubscription<Object?>>[];

  /// False until [start] succeeded, so a late state change from a tray that
  /// never came up can't call into the platform.
  bool _started = false;

  /// Tracked here (not queried from the platform) because the only ways the
  /// window hides are the close button and the tray's Hide row, both of which
  /// pass through this class.
  bool _windowVisible = true;

  /// The state the last [apply] rendered, so the frequent `connectionProvider`
  /// updates (traffic counters on every health tick) don't rebuild the native
  /// menu when nothing the tray shows has changed.
  Object? _lastRendered;

  /// Wires the platform and starts mirroring connection state into the menu.
  ///
  /// A platform that cannot host a tray returns false, in which case nothing
  /// is subscribed and the close button keeps quitting as before.
  Future<void> start() async {
    final available = await _platform.start(
      onCloseRequested: _handleClose,
      onIconClicked: _toggleWindow,
      onAction: _handleAction,
    );
    if (!available) {
      AppLog.info('desktop tray unavailable; window close quits as before');
      return;
    }
    _started = true;
    _subs
      ..add(
        _container.listen(
          authProvider,
          (_, _) => unawaited(_sync()),
          fireImmediately: true,
        ),
      )
      ..add(
        _container.listen(connectionProvider, (_, _) => unawaited(_sync())),
      );
  }

  /// Swaps in new localized labels (a locale change), refreshing the menu.
  void updateLabels(TrayLabels labels) {
    if (labels == _labels) return;
    _labels = labels;
    if (_started) unawaited(_sync());
  }

  Future<void> dispose() async {
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
    await _platform.dispose();
  }

  void _handleClose() => unawaited(_hide());

  void _toggleWindow() => unawaited(_windowVisible ? _hide() : _show());

  void _handleAction(TrayAction action) => switch (action) {
    TrayAction.show => unawaited(_show()),
    TrayAction.hide => unawaited(_hide()),
    TrayAction.connect => unawaited(_connect()),
    TrayAction.disconnect => unawaited(_disconnect()),
    TrayAction.quit => unawaited(_quit()),
  };

  Future<void> _show() async {
    _windowVisible = true;
    await _guard(_platform.showWindow, 'show window');
    await _sync();
  }

  Future<void> _hide() async {
    _windowVisible = false;
    await _guard(_platform.hideWindow, 'hide window');
    await _sync();
  }

  Future<void> _connect() async {
    if (!_authenticated) return;
    await _guard(
      () => _container.read(connectionProvider.notifier).quickConnect(),
      'connect',
    );
  }

  Future<void> _disconnect() async {
    await _guard(
      () => _container.read(connectionProvider.notifier).disconnect(),
      'disconnect',
    );
  }

  Future<void> _quit() => _guard(_platform.quit, 'quit');

  Future<void> _sync() async {
    if (!_started) return;
    final phase = _container.read(connectionProvider).phase;
    final key = (
      authenticated: _authenticated,
      connected: phase == ConnPhase.connected,
      busy: phase == ConnPhase.working,
      windowVisible: _windowVisible,
      labels: _labels,
    );
    if (key == _lastRendered) return;
    _lastRendered = key;
    final presentation = buildTrayPresentation(
      labels: _labels,
      authenticated: key.authenticated,
      connected: key.connected,
      busy: key.busy,
      windowVisible: key.windowVisible,
    );
    await _guard(() => _platform.apply(presentation), 'update menu');
  }

  bool get _authenticated =>
      _container.read(authProvider).value?.status == AuthStatus.authenticated;

  /// Runs a platform/controller call, logging instead of propagating: a tray
  /// failure must never take the app down or wedge the UI.
  Future<void> _guard(Future<void> Function() op, String what) async {
    try {
      await op();
    } catch (e) {
      AppLog.error('desktop tray $what failed', e);
    }
  }
}

/// Wraps the app so the tray icon exists for the whole session.
///
/// Placed under `MaterialApp` so [AppLocalizations] is available for the menu
/// labels; a no-op on mobile, web and under `flutter test`.
class DesktopTrayHost extends ConsumerStatefulWidget {
  const DesktopTrayHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopTrayHost> createState() => _DesktopTrayHostState();
}

class _DesktopTrayHostState extends ConsumerState<DesktopTrayHost> {
  late final TrayPlatform? _platform = createSystemTrayPlatform();
  DesktopTray? _tray;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final platform = _platform;
    if (platform == null) return;
    final l10n = AppLocalizations.of(context);
    final labels = TrayLabels(
      tooltip: l10n.appTitle,
      show: l10n.trayShow,
      hide: l10n.trayHide,
      connect: l10n.trayConnect,
      disconnect: l10n.trayDisconnect,
      quit: l10n.trayQuit,
    );
    final tray = _tray;
    if (tray == null) {
      final created = DesktopTray(
        container: ProviderScope.containerOf(context, listen: false),
        platform: platform,
        labels: labels,
      );
      _tray = created;
      unawaited(created.start());
    } else {
      tray.updateLabels(labels);
    }
  }

  @override
  void dispose() {
    unawaited(_tray?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
