import '../features/vpn/data/models.dart';

/// Connected-tunnel dial params for the Home previews.
const previewDial = DialParams(
  deviceId: 'dev-preview',
  assignedIp: '10.8.0.2',
  serverId: 's-fra-01',
  serverName: 'fra-01',
  endpoint: 'fra-01.example.com',
  wgPort: 51820,
  wgDns: '10.8.0.1',
  wgPublicKey: 'preview-public-key',
);

/// Discovery payload for the Regions previews: one region with two servers
/// and one without dialable capacity.
const previewRegions = [
  Region(
    id: 'r-fra',
    name: 'Frankfurt',
    countryCode: 'DE',
    servers: [
      DiscoveryServer(
        id: 's-fra-01',
        name: 'fra-01',
        endpoint: 'fra-01.example.com',
        wgPort: 51820,
        wgDns: '10.8.0.1',
        activePeers: 12,
      ),
      DiscoveryServer(
        id: 's-fra-02',
        name: 'fra-02',
        endpoint: 'fra-02.example.com',
        wgPort: 51820,
        wgDns: '10.8.0.1',
        activePeers: 3,
      ),
    ],
  ),
  Region(id: 'r-empty', name: 'Nowhere', countryCode: 'US'),
];
