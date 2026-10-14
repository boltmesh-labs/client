// Unit tests for the extracted transport ladder: the rung state and the pure
// rules that select, walk and describe it, exercised without a controller or a
// provider container. The end-to-end behaviour (a heal demoting, a move
// following the node's list) stays covered by the state suites; this locks the
// ladder's own contract so the collaborator cannot drift from its callers.

import 'package:boltmesh/features/vpn/data/helper_client.dart'
    show capStreamTransport;
import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/state/transport_ladder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/vpn_harness.dart';

/// A ladder whose ambient inputs the test controls: the daemon capability set
/// and the e2e force seam, both read lazily.
TransportLadder ladderFor({
  Set<String> capabilities = const <String>{},
  TransportRung? forced,
}) => TransportLadder(
  daemonCapabilities: () => capabilities,
  forcedRung: () => forced,
);

DialParams dial({int? awgPort, Map<String, dynamic>? stream}) =>
    DialParams.fromJson(dialJson(awgPort: awgPort, stream: stream));

void main() {
  group('floor and walk', () {
    test('floors a high sticky rung back onto the node\'s list', () {
      final ladder = ladderFor()..rung = TransportRung.stream;
      // The node serves native + awg; a sticky stream rung is not advertised
      // and clamps to the ceiling.
      expect(ladder.rungFor(dial(awgPort: 51821)), TransportRung.awg);
    });

    test('walks one rung at a time and stops at the bottom', () {
      final d = dial(awgPort: 51821);
      final ladder = ladderFor();
      expect(ladder.hasLowerRung(d), isTrue);
      expect(ladder.demoteRung(d, 'test'), isTrue);
      expect(ladder.rung, TransportRung.awg);
      // At the bottom of this node's list there is nothing left to step onto.
      expect(ladder.hasLowerRung(d), isFalse);
      expect(ladder.demoteRung(d, 'test'), isFalse);
    });

    test('a force seam is honored only while the rung is advertised', () {
      final d = dial(awgPort: 51821);
      expect(
        ladderFor(forced: TransportRung.awg).rungFor(d),
        TransportRung.awg,
      );
      // stream is not on this node's list, so the seam is ignored.
      expect(
        ladderFor(forced: TransportRung.stream).rungFor(d),
        TransportRung.native,
      );
    });

    test('refuses a payload with no runnable entry', () {
      // An entry whose rung name is unknown decodes to null and is not a rung,
      // so the ladder has nothing to start on.
      final empty = DialParams.fromJson({
        ...dialJson(),
        'transports': [
          {'rung': 'not-a-rung', 'port': 1},
        ],
      });
      final ladder = ladderFor();
      expect(ladder.rungFor(empty), isNull);
      expect(() => ladder.apply(empty), throwsUnsupportedError);
    });
  });

  group('rung-derived config', () {
    test('native uses the stock overlay and no obfuscation', () {
      final d = dial(awgPort: 51821);
      final ladder = ladderFor();
      expect(ladder.overlayAddressFor(d), '10.8.0.5');
      expect(ladder.overlayDnsFor(d), '10.8.0.1');
      expect(ladder.tunnelPortFor(d), 51820);
      expect(ladder.obfuscationParamsFor(d), isNull);
    });

    test('awg uses the obfuscated overlay and the rung\'s own port', () {
      final d = dial(awgPort: 51821);
      final ladder = ladderFor()..rung = TransportRung.awg;
      expect(ladder.overlayAddressFor(d), '10.9.0.5');
      expect(ladder.overlayDnsFor(d), '10.9.0.1');
      expect(ladder.tunnelPortFor(d), 51821);
      expect(ladder.obfuscationParamsFor(d), isNotNull);
    });
  });

  group('stream rung gate', () {
    final d = dial(stream: streamTransportJson());

    test('is not runnable without the daemon capability', () {
      expect(ladderFor().runnableRungs(d), [TransportRung.native]);
    });

    test('is admitted when the helper advertises the capability', () {
      expect(
        ladderFor(capabilities: const {capStreamTransport}).runnableRungs(d),
        [TransportRung.native, TransportRung.stream],
      );
    });
  });
}
