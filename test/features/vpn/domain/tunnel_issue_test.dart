import 'package:boltmesh/core/errors.dart';
import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/domain/tunnel_issue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The daemon's message for the reported failure, verbatim.
  const daemonText =
      'obfuscated up: configure device: IPC error -22: failed to set endpoint '
      'node.example.net:51820: No such host is known.';

  test('the backend copy wins when it answered', () {
    expect(
      failureReason(
        const ApiException(ApiErrorKind.noCapacity, 'No capacity right now.'),
        HelperException('internal', daemonText),
      ),
      'No capacity right now.',
    );
  });

  test('a helper failure is projected, never rendered raw', () {
    for (final code in ['bad_config', 'unavailable', 'internal']) {
      final shown = failureReason(null, HelperException(code, daemonText));
      expect(shown, isNot(contains('IPC error')));
      expect(shown, isNot(contains('No such host')));
      expect(shown, isNot(contains('HelperException')));
      expect(shown.trim(), isNotEmpty);
    }
  });

  test('each daemon code says something different', () {
    final shown = [
      for (final code in ['bad_config', 'unavailable', 'internal'])
        failureReason(null, HelperException(code, daemonText)),
    ];
    expect(shown.toSet(), hasLength(3));
  });

  test('an unreachable helper names the helper, not the socket', () {
    final shown = failureReason(
      null,
      HelperTransportException(
        'helper socket unavailable: Connection refused (OS Error: 111)',
      ),
    );
    expect(shown, contains('helper service'));
    expect(shown, isNot(contains('OS Error')));
  });

  test('an unknown code still gets an actionable sentence', () {
    expect(
      failureReason(null, HelperException('something_new', daemonText)),
      isNot(contains('IPC error')),
    );
  });

  // Every other error the VPN layer raises is already written for the user, so
  // flattening it into a generic sentence would throw away better copy. These
  // are the two guards in the VPN layer that rely on that: an identity mismatch
  // and a server offering no rung this build can start.
  test('non-helper errors keep their own copy', () {
    for (final e in [
      StateError('Missing private key. Reprovision.'),
      UnsupportedError(
        'The server "eu-1" offers no transport this app build can use. '
        'Choose another server.',
      ),
    ]) {
      expect(failureReason(null, e), e.toString());
    }
  });
}
