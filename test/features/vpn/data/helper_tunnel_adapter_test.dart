import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/data/helper_tunnel_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

class _QueueSocket implements HelperSocket {
  _QueueSocket(this._steps);

  final List<Object> _steps;
  final List<Map<String, dynamic>> requests = [];

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> request) async {
    requests.add(request);
    if (_steps.isEmpty) {
      throw StateError('no scripted response for ${request['op']}');
    }
    final step = _steps.removeAt(0);
    if (step is Exception) throw step;
    return step as Map<String, dynamic>;
  }
}

Map<String, dynamic> _ok(Map<String, dynamic> status) => {
  'v': helperProtocolVersion,
  'id': '1',
  'ok': true,
  'status': status,
};

Map<String, dynamic> _status({
  bool up = true,
  String stage = 'connected',
  int rx = 0,
  int tx = 0,
  int handshake = 0,
  String endpoint = '',
  String publicKey = '',
}) => {
  'interface': 'boltmesh0',
  'up': up,
  'stage': stage,
  'rxBytes': rx,
  'txBytes': tx,
  'lastHandshake': handshake,
  'endpoint': endpoint,
  'publicKey': publicKey,
};

HelperTunnelAdapter _adapter(_QueueSocket socket) =>
    HelperTunnelAdapter(client: HelperClient(socket: socket));

void main() {
  test('ensureInitialized pings and marks ready', () async {
    final socket = _QueueSocket([
      _ok(_status(up: false, stage: 'disconnected')),
    ]);
    final adapter = _adapter(socket);

    await adapter.ensureInitialized();

    expect(socket.requests.single['op'], 'ping');
    expect(adapter.isReady, isTrue);
  });

  test('start sends the config and readStage reflects the daemon', () async {
    final socket = _QueueSocket([_ok(_status()), _ok(_status())]);
    final adapter = _adapter(socket);

    await adapter.start(
      serverAddress: '203.0.113.10:51820',
      wgQuickConfig: '[Interface]\nPrivateKey = x\n',
      providerBundleId: '',
    );

    expect(socket.requests[0]['op'], 'up');
    expect(socket.requests[0]['config'], '[Interface]\nPrivateKey = x\n');
    expect(await adapter.readStage(), VpnStage.connected);
  });

  test('readStage maps connecting and unknown-on-error', () async {
    final connecting = _adapter(
      _QueueSocket([_ok(_status(stage: 'connecting'))]),
    );
    expect(await connecting.readStage(), VpnStage.connecting);

    final broken = _adapter(_QueueSocket([HelperTransportException('down')]));
    expect(await broken.readStage(), isNull);
  });

  test('readTraffic reports counters while up, null while down', () async {
    final up = _adapter(_QueueSocket([_ok(_status(rx: 100, tx: 200))]));
    expect(await up.readTraffic(), {'rxBytes': 100, 'txBytes': 200});

    final down = _adapter(
      _QueueSocket([_ok(_status(up: false, stage: 'disconnected'))]),
    );
    expect(await down.readTraffic(), isNull);
  });

  test('readHandshake converts epoch seconds and nulls a zero', () async {
    final handshook = _adapter(
      _QueueSocket([_ok(_status(handshake: 1718000000))]),
    );
    expect(
      await handshook.readHandshake(),
      DateTime.fromMillisecondsSinceEpoch(1718000000 * 1000, isUtc: true),
    );

    final never = _adapter(_QueueSocket([_ok(_status())]));
    expect(await never.readHandshake(), isNull);
  });

  test('getActivePeer returns the newest peer, null when empty', () async {
    final peer = _adapter(
      _QueueSocket([
        _ok(_status(publicKey: 'PUBKEY=', endpoint: '198.51.100.7:1234')),
      ]),
    );
    final active = await peer.getActivePeer();
    expect(active, isNotNull);
    expect(active!.publicKey, 'PUBKEY=');
    expect(active.endpoint, '198.51.100.7:1234');

    final none = _adapter(_QueueSocket([_ok(_status())]));
    expect(await none.getActivePeer(), isNull);
  });

  test('stop retries once and never throws', () async {
    final socket = _QueueSocket([
      HelperTransportException('first attempt failed'),
      _ok(_status(up: false, stage: 'disconnected')),
    ]);
    final adapter = _adapter(socket);

    await adapter.stop('test');

    expect(socket.requests.length, 2);
    expect(socket.requests.every((r) => r['op'] == 'down'), isTrue);
  });

  test('stop gives up quietly when both attempts fail', () async {
    final socket = _QueueSocket([
      HelperTransportException('first'),
      HelperTransportException('second'),
    ]);
    final adapter = _adapter(socket);

    await adapter.stop('test');

    expect(socket.requests.length, 2);
  });

  test('killGhost downs the tunnel and reports success', () async {
    final gone = _adapter(
      _QueueSocket([_ok(_status(up: false, stage: 'disconnected'))]),
    );
    expect(await gone.killGhost(), isTrue);

    final broken = _adapter(_QueueSocket([HelperTransportException('down')]));
    expect(await broken.killGhost(), isFalse);
  });

  test('helper adapter advertises handshake support with no push stages', () {
    final adapter = _adapter(_QueueSocket([]));
    expect(adapter.handshakeReaderSupported, isTrue);
    expect(adapter.stages, emitsDone);
  });
}
