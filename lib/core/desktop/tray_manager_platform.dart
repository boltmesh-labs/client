import 'tray_manager_platform_stub.dart'
    if (dart.library.io) 'tray_manager_platform_io.dart'
    as implementation;

import 'tray_platform.dart';

/// Whether the Flutter test runner is active on this platform.
bool get isDesktopUnderTest => implementation.isDesktopUnderTest;

/// Whether the current platform supports the desktop tray/window backend.
bool get isDesktopPlatform => implementation.isDesktopPlatform;

/// Whether the desktop tray feature should be initialized.
bool get supportsDesktopTray => implementation.supportsDesktopTray;

/// Initializes the desktop window backend when applicable.
Future<void> initDesktopWindow() => implementation.initDesktopWindow();

/// Updates the native desktop window title when applicable.
Future<void> setDesktopWindowTitle(String title) =>
    implementation.setDesktopWindowTitle(title);

/// Creates the native tray platform when applicable.
TrayPlatform? createSystemTrayPlatform() =>
    implementation.createSystemTrayPlatform();
