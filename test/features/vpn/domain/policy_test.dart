import 'package:boltmesh/features/vpn/data/models.dart';
import 'package:boltmesh/features/vpn/domain/region_policy.dart';
import 'package:boltmesh/features/vpn/domain/tunnel_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

DiscoveryServer srv(String id, int peers) => DiscoveryServer(
  id: id,
  name: id,
  endpoint: 'e.example.com',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  activePeers: peers,
);

void main() {
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
    bool stale(DateTime? since) =>
        isHandshakeStale(lastHandshakeAt: null, now: now, connectedAt: since);
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
