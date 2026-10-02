import 'log_file_stub.dart'
    if (dart.library.io) 'log_file_io.dart'
    as implementation;

/// Whether the Flutter test runner is active. Mirrors `isDesktopUnderTest` in
/// `desktop/tray_manager_platform_io.dart`: the suites set `FLUTTER_TEST`, and
/// a file sink must never write into the developer's real log directory while
/// tests run. [setLogDirectory] overrides this for the sink's own tests.
bool get isUnderTest => implementation.isUnderTest;

/// Persists one already-formatted log line, rotating the file when it grows
/// past its cap. Best-effort: a failure here is swallowed, because a logging
/// fault must never be the thing that breaks the app.
void writeLogLine(String line) => implementation.writeLogLine(line);

/// The directory the sink writes into, or null when file logging is
/// unavailable (web, or a test run that has not opted in).
String? get logDirectory => implementation.logDirectory;

/// Points the sink at [directory] instead of the platform default. For tests;
/// null restores the default resolution.
void setLogDirectory(String? directory) =>
    implementation.setLogDirectory(directory);
