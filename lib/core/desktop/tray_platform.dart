/// Platform seam for the desktop tray icon and the close-to-hide behavior.
///
/// One interface keeps every `tray_manager`/`window_manager` call in a single
/// implementation ([TrayManagerPlatform]), so [DesktopTray] can be exercised
/// against a fake without a native window and the app's close-to-quit
/// fallback is decided in one place.
library;

import 'tray_menu.dart';

/// Low-level desktop window/tray operations.
abstract interface class TrayPlatform {
  /// Creates the tray icon and starts intercepting the window's close button.
  ///
  /// Returns false when this machine cannot host a usable tray (no icon could
  /// be created, or the window backend failed). The caller must then leave the
  /// default close-to-quit behavior alone instead of stranding a hidden
  /// window with no way back.
  Future<bool> start({
    required void Function() onCloseRequested,
    required void Function() onIconClicked,
    required void Function(TrayAction action) onAction,
  });

  /// Renders [presentation]: icon tooltip + context menu. Safe to call
  /// repeatedly; the implementation owns the native menu lifetime.
  Future<void> apply(TrayPresentation presentation);

  /// Restores and focuses the app window.
  Future<void> showWindow();

  /// Hides the app window, leaving the process (and any tunnel) running.
  Future<void> hideWindow();

  /// Terminates the process; the tray's Quit row. Does not disconnect first:
  /// the OS tunnel survives a quit exactly as it does today.
  Future<void> quit();

  /// Releases the tray icon and restores close-to-quit.
  Future<void> dispose();
}
