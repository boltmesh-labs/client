/// Real [TrayPlatform] over `tray_manager` (icon + menu) and
/// `window_manager` (hide/show/focus + close-button interception).
///
/// This is the only file that talks to the desktop plugins, and the only place
/// the per-platform conventions differ: on Windows a left-click is the primary
/// action (restore) with the menu on right-click, while macOS/Linux open the
/// menu on any click. Linux additionally *requires* the `clicked` trigger: the
/// StatusNotifier menu is only exported over D-Bus when the trigger is
/// `clicked`, and the panel never forwards raw icon clicks to Dart.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../log.dart';
import 'tray_menu.dart';
import 'tray_platform.dart';

/// Bundled launcher icon, reused as the tray glyph (scaled by the OS/panel).
const _iconAsset = 'assets/icon/app_icon.png';

/// Flutter's test runner sets `FLUTTER_TEST`; the desktop plugins have no
/// native side there and there is no window to hide, so the whole feature
/// stays off so the widget suites never touch a platform channel.
bool get isDesktopUnderTest => Platform.environment.containsKey('FLUTTER_TEST');

/// True on a desktop platform where the tray/window plugins apply.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Whether the tray + close-to-hide feature should be wired up at all.
bool get supportsDesktopTray => isDesktopPlatform && !isDesktopUnderTest;

/// `window_manager` requires initialization before `runApp`. No-op off desktop
/// and under tests.
Future<void> initDesktopWindow() async {
  if (!supportsDesktopTray) return;
  await windowManager.ensureInitialized();
}

/// The real tray backend, or null when the tray feature does not apply
/// (mobile/web, or `flutter test`).
TrayPlatform? createSystemTrayPlatform() =>
    supportsDesktopTray ? TrayManagerPlatform() : null;

/// `tray_manager` + `window_manager` implementation of [TrayPlatform].
class TrayManagerPlatform with WindowListener implements TrayPlatform {
  TrayIcon? _icon;

  void Function()? _onClose;
  void Function()? _onIconClicked;
  void Function(TrayAction)? _onAction;
  bool _started = false;

  @override
  Future<bool> start({
    required void Function() onCloseRequested,
    required void Function() onIconClicked,
    required void Function(TrayAction action) onAction,
  }) async {
    _onClose = onCloseRequested;
    _onIconClicked = onIconClicked;
    _onAction = onAction;
    try {
      // Intercept the close button before creating the icon: if the tray
      // turns out to be unavailable, `_stopWindowInterceptor` restores the
      // normal quit so the user is never left with an unreachable window.
      if (Platform.isLinux && !await _hasStatusNotifierHost()) {
        AppLog.info('no Linux StatusNotifier host; close button quits');
        return false;
      }
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      final icon = TrayIcon.create();
      if (icon == null) {
        await _stopWindowInterceptor();
        AppLog.info('tray icon creation failed; close button quits as before');
        return false;
      }
      final image = ImageAsset.fromAsset(_iconAsset);
      if (image == null) {
        AppLog.error('tray icon asset unavailable ($_iconAsset)');
      } else {
        icon.icon = image;
        icon.iconSize = const Size(18, 18);
      }
      // See the library doc: Linux needs `clicked` for the menu to exist at
      // all; Windows keeps the menu on right-click so left-click can restore.
      icon.setContextMenuTrigger(
        Platform.isWindows
            ? ContextMenuTrigger.rightClicked
            : ContextMenuTrigger.clicked,
      );
      icon.addListener(_handleTrayEvent);
      if (!icon.setVisible(true)) {
        icon.dispose();
        await _stopWindowInterceptor();
        AppLog.info('tray not visible on this desktop; close button quits');
        return false;
      }
      _icon = icon;
      _started = true;
      return true;
    } catch (e) {
      AppLog.error('desktop tray start failed', e);
      await _stopWindowInterceptor();
      return false;
    }
  }

  @override
  Future<void> apply(TrayPresentation presentation) async {
    final icon = _icon;
    if (icon == null) return;
    try {
      icon.setTooltip(presentation.tooltip);
      final menu = Menu.create();
      if (menu == null) {
        AppLog.error('tray menu creation failed');
        return;
      }
      for (final entry in presentation.entries) {
        if (entry.isSeparator) {
          menu.addSeparator();
          continue;
        }
        final action = entry.action;
        final label = entry.label;
        if (action == null || label == null) continue;
        final item = MenuItem.createWithLabelAndType(
          label,
          MenuItemType.normal,
        );
        if (item == null) continue;
        item.isEnabled = entry.enabled;
        item.addListener((event) {
          if (event is MenuItemClickedEvent) _onAction?.call(action);
        });
        menu.addItem(item);
      }
      // The icon takes a native (shared_ptr) reference to the menu, and the
      // menu to each item, so the Dart wrappers can be collected once this
      // returns; the next `apply` simply swaps in a freshly built menu.
      icon.setContextMenu(menu);
    } catch (e) {
      AppLog.error('tray menu update failed', e);
    }
  }

  @override
  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hideWindow() => windowManager.hide();

  @override
  Future<void> quit() => windowManager.destroy();

  @override
  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    _icon?.dispose();
    _icon = null;
    await _stopWindowInterceptor();
  }

  @override
  void onWindowClose() => unawaited(_handleWindowClose());

  /// Per-platform clicks: Windows left/double-click restores the window while
  /// the menu owns right-click; macOS needs an explicit open for right-click.
  /// Linux never delivers icon clicks to Dart.
  void _handleTrayEvent(TrayIconEvent event) {
    switch (event) {
      case TrayIconClickedEvent():
        if (Platform.isWindows) _onIconClicked?.call();
      case TrayIconDoubleClickedEvent():
        if (Platform.isWindows) _onIconClicked?.call();
      case TrayIconRightClickedEvent():
        if (Platform.isMacOS) _icon?.openContextMenu();
    }
  }

  /// GNOME without AppIndicator can still let the SNI item register from the
  /// app's point of view, while providing no visible panel host. Do not hide
  /// the window in that case: restore normal close-to-quit behavior instead.
  Future<void> _handleWindowClose() async {
    if (Platform.isLinux && !await _hasStatusNotifierHost()) {
      AppLog.info('Linux StatusNotifier host disappeared; closing normally');
      await _stopWindowInterceptor();
      await windowManager.destroy();
      return;
    }
    _onClose?.call();
  }

  Future<bool> _hasStatusNotifierHost() async {
    final bus = DBusClient.session();
    try {
      const watcherName = 'org.kde.StatusNotifierWatcher';
      if (!await bus.nameHasOwner(watcherName)) return false;

      final watcher = DBusRemoteObject(
        bus,
        name: watcherName,
        path: DBusObjectPath('/StatusNotifierWatcher'),
      );
      return (await watcher.getProperty(
        watcherName,
        'IsStatusNotifierHostRegistered',
        signature: DBusSignature('b'),
      )).asBoolean();
    } catch (e) {
      AppLog.info('Linux StatusNotifier host probe failed: $e');
      return false;
    } finally {
      await bus.close();
    }
  }

  Future<void> _stopWindowInterceptor() async {
    windowManager.removeListener(this);
    try {
      await windowManager.setPreventClose(false);
    } catch (e) {
      AppLog.error('restore close handling failed', e);
    }
  }
}
