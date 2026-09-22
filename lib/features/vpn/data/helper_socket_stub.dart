// Non-io stub: no sockets without dart:io. The helper adapters are never
// selected here (isHelperPlatformSupported is false), so exchange() is only a
// guard against accidental use.
import 'helper_socket.dart';

bool get isHelperPlatformSupported => false;

HelperSocket createHelperSocket() => _UnsupportedHelperSocket();

class _UnsupportedHelperSocket implements HelperSocket {
  @override
  bool get isSupported => false;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) {
    throw HelperTransportException(
      'boltmeshd is only available on Linux and Windows',
    );
  }
}
