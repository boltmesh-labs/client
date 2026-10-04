import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/domain/region_policy.dart';
import 'package:boltmesh/features/vpn/domain/tunnel_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/vpn_harness.dart';

DiscoveryServer srv(String id, int peers) => DiscoveryServer(
  id: id,
  name: id,
  endpoint: 'e.example.com',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  activePeers: peers,
);

/// A [DialParams] carrying [endpoint] and key [key], for the live-peer
/// comparison.
DialParams liveDial({
  String endpoint = 'node.example.net',
  String key = 'SRV',
}) => DialParams.fromJson(dialJson(endpoint: endpoint, wgPublicKey: key));

void main() {
  // The property this suite exists for: the backend hands out a hostname and
  // the OS reports the address the device resolved it to, so a verbatim string
  // comparison never matched and the strongest cold-restore signal was dead on
  // every desktop read.
  group('livePeerMatchesDial', () {
    test('a resolved address matches the hostname dial it came from', () {
      // The real desktop shape: the dial carries the backend's hostname, the
      // surviving tunnel reports the address it resolved that hostname to.
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '198.51.100.20:51820',
          dial: liveDial(),
        ),
        isTrue,
      );
    });

    test('a literal dial matches the same address reported back', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '203.0.113.10:51820',
          dial: liveDial(endpoint: '203.0.113.10'),
        ),
        isTrue,
      );
    });

    // The Android adapter reports the configured endpoint verbatim, so the
    // name-against-name case has to keep matching exactly.
    test('a name on both sides matches without resolving', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: 'node.example.net:51820',
          dial: liveDial(),
        ),
        isTrue,
      );
    });

    test('a different address for the same key does not match', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '198.51.100.99:51820',
          dial: liveDial(endpoint: '198.51.100.20'),
        ),
        isFalse,
      );
    });

    test('a different port for the same address does not match', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '198.51.100.20:51821',
          dial: liveDial(endpoint: '198.51.100.20'),
        ),
        isFalse,
      );
    });

    test('a missing endpoint is unverifiable, so the key still carries it', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '',
          dial: liveDial(),
        ),
        isTrue,
        reason:
            'an unreadable endpoint is absence of evidence, not contradiction',
      );
    });

    test('the key is the identity: a different key never matches', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'OTHER',
          liveEndpoint: 'node.example.net:51820',
          dial: liveDial(),
        ),
        isFalse,
      );
    });

    test('an unreadable key never matches', () {
      for (final key in ['', '   ']) {
        expect(
          livePeerMatchesDial(
            livePublicKey: key,
            liveEndpoint: 'node.example.net:51820',
            dial: liveDial(),
          ),
          isFalse,
          reason: 'key ${key.isEmpty ? 'empty' : 'blank'} must not corroborate',
        );
      }
    });

    test('IPv6 endpoints match across the bracketed and bare forms', () {
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '[2001:db8::9]:51820',
          dial: liveDial(endpoint: '2001:db8::9'),
        ),
        isTrue,
      );
      expect(
        endpointAgreement('[2001:0db8:0000::9]:51820', '[2001:db8::9]:51820'),
        EndpointAgreement.match,
        reason: 'the same v6 address in two spellings is one address',
      );
    });
  });

  group('endpointAgreement', () {
    test('a name against an address is unverifiable, not a mismatch', () {
      // Deliberately not resolved: on a cold restore this app's resolver may
      // already follow the surviving tunnel, so a lookup could go through the
      // very tunnel being verified. Unverifiable must not veto the key match,
      // or the signal is dead on exactly the desktop shape it exists for.
      expect(
        endpointAgreement('node.example.net:51820', '198.51.100.20:51820'),
        EndpointAgreement.unverifiable,
      );
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: 'node.example.net:51820',
          dial: liveDial(endpoint: '198.51.100.20'),
        ),
        isTrue,
        reason:
            'the key carries the identity when the endpoint cannot be compared',
      );
    });

    test('two literals that differ are a mismatch, and it vetoes', () {
      expect(
        endpointAgreement('198.51.100.99:51820', '198.51.100.20:51820'),
        EndpointAgreement.mismatch,
      );
      expect(
        livePeerMatchesDial(
          livePublicKey: 'SRV',
          liveEndpoint: '198.51.100.99:51820',
          dial: liveDial(endpoint: '198.51.100.20'),
        ),
        isFalse,
      );
    });

    test('a differing port is a mismatch even with a name on one side', () {
      // The port is comparable without resolving anything, so it is not part of
      // the unverifiable bucket.
      expect(
        endpointAgreement('node.example.net:51821', '198.51.100.20:51820'),
        EndpointAgreement.mismatch,
      );
    });

    test('equal strings match without parsing', () {
      expect(
        endpointAgreement('node.example.net:51820', 'node.example.net:51820'),
        EndpointAgreement.match,
      );
    });

    test('a v4-mapped literal is a different address from the plain v4', () {
      expect(
        endpointAgreement(
          '[::ffff:198.51.100.20]:51820',
          '198.51.100.20:51820',
        ),
        EndpointAgreement.mismatch,
      );
    });

    test('unparseable values are unverifiable, never a mismatch', () {
      for (final pair in [
        ('', '198.51.100.20:51820'),
        ('198.51.100.20:51820', ''),
        ('garbage', '198.51.100.20:51820'),
        ('198.51.100.20', '198.51.100.20:51820'),
        ('2001:db8::9:51820', '198.51.100.20:51820'),
        ('198.51.100.20:notaport', '198.51.100.20:51820'),
      ]) {
        expect(
          endpointAgreement(pair.$1, pair.$2),
          EndpointAgreement.unverifiable,
          reason: '"${pair.$1}" vs "${pair.$2}" must not be a mismatch',
        );
      }
    });
  });

  test('isDegradedStage flags waiting states only', () {
    expect(isDegradedStage(VpnStage.waitingConnection), isTrue);
    expect(isDegradedStage(VpnStage.reconnect), isTrue);
    expect(isDegradedStage(VpnStage.noConnection), isTrue);
    expect(isDegradedStage(VpnStage.connected), isFalse);
    expect(isDegradedStage(VpnStage.disconnected), isFalse);
  });

  test('extractRxBytes is rx-only, null otherwise', () {
    expect(extractRxBytes({'rx_bytes': 100, 'tx_bytes': 50}), 100);
    expect(extractRxBytes({'tx_bytes': 50}), isNull);
    expect(extractRxBytes({}), isNull);
    expect(
      extractRxBytes({
        'peer': {'rx_bytes': 10, 'port': 51820},
      }),
      10,
    );
    expect(extractRxBytes({'wgPort': 51820, 'peers': 3}), isNull);
    expect(
      extractRxBytes({
        'peers': [
          {'rx_bytes': 5},
          {'port': 51820},
        ],
      }),
      5,
    );
    expect(extractRxBytes({'lastHandshake': 1718000000}), isNull);
  });

  test('extractors split plugin totals, skip speed rates', () {
    const plugin = {
      'totalDownload': 100,
      'totalUpload': 50,
      'downloadSpeed': 5,
      'uploadSpeed': 3,
      'duration': '00:00:01',
    };
    expect(extractRxBytes(plugin), 100);
    expect(extractTxBytes(plugin), 50);
    expect(extractTxBytes({'rx_bytes': 100}), isNull);
    expect(extractRxBytes({'tx_bytes': 50}), isNull);
    expect(extractTxBytes({'wgPort': 51820, 'peers': 3}), isNull);
    expect(
      extractTxBytes({
        'peer': {'tx_bytes': 7, 'port': 51820},
      }),
      7,
    );
    expect(extractRxBytes({'downloadSpeed': 9}), isNull);
    expect(extractTxBytes({'uploadSpeed': 9}), isNull);
  });

  test('formatBytes renders B/KB/MB/GB with one decimal', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(12 * 1024 * 1024), '12.0 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    expect(formatBytes(-5), '0 B');
  });

  test('isHandshakeStale ages out observed handshakes after the window', () {
    final now = DateTime.utc(2026, 9, 19, 12);
    bool stale(DateTime? last, {bool supported = true}) => isHandshakeStale(
      lastHandshakeAt: last,
      now: now,
      readerSupported: supported,
      graceAfter: const Duration(seconds: 45),
      staleAfter: const Duration(seconds: 150),
    );
    expect(stale(now), isFalse);
    expect(stale(now.subtract(const Duration(seconds: 149))), isFalse);
    expect(stale(now.subtract(const Duration(seconds: 150))), isTrue);
    expect(stale(now.subtract(const Duration(minutes: 5))), isTrue);
    // Future timestamps (clock skew) are fresh, never stale.
    expect(stale(now.add(const Duration(seconds: 10))), isFalse);
    // Observed handshakes age out regardless of reader support.
    expect(
      stale(now.subtract(const Duration(minutes: 5)), supported: false),
      isTrue,
    );
  });

  test('isHandshakeStale: never-handshook only needs the grace window', () {
    final now = DateTime.utc(2026, 9, 19, 12);
    // The windows are the caller's to pass (see the function's doc): a
    // deliberate no-defaults API, so each caller states which bar it means.
    bool stale(DateTime? since) => isHandshakeStale(
      lastHandshakeAt: null,
      now: now,
      connectedAt: since,
      graceAfter: const Duration(seconds: 45),
      staleAfter: const Duration(seconds: 150),
    );
    expect(stale(null), isFalse);
    expect(stale(now.subtract(const Duration(seconds: 10))), isFalse);
    expect(stale(now.subtract(const Duration(seconds: 44))), isFalse);
    // A supported reader that keeps reporting "no handshake yet" while the
    // WireGuard core retries every 5s proves the peer dead well before the
    // full rekey window.
    expect(stale(now.subtract(const Duration(seconds: 45))), isTrue);
    expect(stale(now.subtract(const Duration(minutes: 5))), isTrue);
  });

  test('isHandshakeStale: unsupported reader null is never stale', () {
    final now = DateTime.utc(2026, 9, 19, 12);
    bool stale(DateTime? since) => isHandshakeStale(
      lastHandshakeAt: null,
      now: now,
      connectedAt: since,
      readerSupported: false,
      graceAfter: const Duration(seconds: 45),
      staleAfter: const Duration(seconds: 150),
    );
    expect(stale(null), isFalse);
    // Absence of evidence: hours without a read prove nothing — the
    // degraded-stage path still heals those platforms.
    expect(stale(now.subtract(const Duration(hours: 1))), isFalse);
  });

  test('autoPickRegion skips empty regions, picks lowest load', () {
    const empty = Region(id: 'e', name: 'E', countryCode: 'US');
    final a = Region(
      id: 'a',
      name: 'A',
      countryCode: 'DE',
      servers: [srv('s1', 10)],
    );
    final b = Region(
      id: 'b',
      name: 'B',
      countryCode: 'DE',
      servers: [srv('s2', 3)],
    );
    expect(autoPickRegion([empty, a, b])?.id, 'b');
    expect(autoPickRegion([empty]), isNull);
    expect(regionLoad(a), 10);
  });

  test('autoPickRegion does not filter on format', () {
    // The filter this replaced asked whether this build could produce a datagram
    // for a node's *obfuscation* format, and on a platform with no obfuscated
    // data plane that excluded regions whose stock device was readable right
    // there. It could only ever exclude regions that would have worked. Now every
    // region leads with `native`, so the only question left is capacity.
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final light = Region(
      id: 'light',
      name: 'Light',
      countryCode: 'DE',
      servers: [srv('s1', 1)],
    );
    final heavy = Region(
      id: 'heavy',
      name: 'Heavy',
      countryCode: 'US',
      servers: [srv('s2', 9)],
    );
    expect(autoPickRegion([heavy, light])?.id, 'light');
  });

  test('regionsVisible filters by query and sorts by load', () {
    final a = Region(
      id: 'a',
      name: 'Frankfurt',
      countryCode: 'DE',
      servers: [srv('s1', 10)],
    );
    const b = Region(
      id: 'b',
      name: 'Ashburn',
      countryCode: 'US',
      servers: [
        DiscoveryServer(
          id: 's2',
          name: 'us-east',
          endpoint: 'us.example.com',
          wgPort: 51820,
          wgDns: '10.8.0.1',
          activePeers: 3,
        ),
      ],
    );
    // Empty query keeps everything, load-ascending.
    expect(regionsVisible([a, b], '').map((r) => r.id).toList(), ['b', 'a']);
    // Region name, region country, server name, server endpoint.
    expect(regionsVisible([a, b], 'frank').single.id, 'a');
    expect(regionsVisible([a, b], 'de').single.id, 'a');
    expect(regionsVisible([a, b], 'us-east').single.id, 'b');
    expect(regionsVisible([a, b], 'us.example').single.id, 'b');
    expect(regionsVisible([a, b], 'nope'), isEmpty);
  });
}
