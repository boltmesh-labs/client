/// Web stub for the stream node resolver.
///
/// The stream rung only runs where `dart:io` sockets exist, so this is
/// unreachable — but the shared data layer still has to compile on web. The
/// conditional import in `tunnel_adapter.dart` picks the io implementation
/// there.
library;

/// Unreachable on web: never called, because no web build offers the rung.
Future<String> resolveStreamServer(String server) =>
    throw UnsupportedError('stream transport is unavailable on this platform');
