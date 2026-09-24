import 'tray_platform.dart';

/// Web has no desktop window or tray backend.
bool get isDesktopUnderTest => false;

bool get isDesktopPlatform => false;

bool get supportsDesktopTray => false;

Future<void> initDesktopWindow() async {}

Future<void> setDesktopWindowTitle(String title) async {}

TrayPlatform? createSystemTrayPlatform() => null;
