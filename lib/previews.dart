/// Widget Previewer entries (stable since Flutter 3.47).
///
/// The previews live under `lib/previews/`: `harness.dart` holds the
/// offline fakes + shell wrapper (the previewer runs on Flutter Web, where
/// `wireguard_flutter_plus` / `flutter_secure_storage` are unavailable),
/// `fixtures.dart` the sample data, and one file per screen group holds the
/// `@Preview` entries themselves. The previewer scans the whole of `lib/`,
/// so this barrel is the documented entry point, not a registry.
///
/// `.widget_preview/` stays gitignored; only `lib/previews.dart` and
/// `lib/previews/` are checked in.
library;

export 'previews/fixtures.dart';
export 'previews/harness.dart';
export 'previews/home.dart';
export 'previews/login.dart';
export 'previews/regions.dart';
export 'previews/settings.dart';
