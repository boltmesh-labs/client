/// Web has no `dart:io`, so there is nowhere to persist a line. The sink is a
/// no-op there and [AppLog] keeps its console-only behaviour.
bool get isUnderTest => false;

void writeLogLine(String line) {}

String? get logDirectory => null;

void setLogDirectory(String? directory) {}
