import 'package:boltmesh/features/vpn/data/helper_client.dart';
import 'package:boltmesh/features/vpn/data/helper_socket.dart';
import 'package:boltmesh/features/vpn/data/helper_tunnel_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../../../support/fakes.dart' as support;

HelperTunnelAdapter _adapter(HelperSocket socket) =>
    HelperTunnelAdapter(client: HelperClient(socket: socket));

void main() {
  test('ensureInitialized pings and marks ready', () async {
    final socket = support.ScriptedHelperSocket([
      support.helperOk(
        support.helperStatusJson(up: false, stage: 'disconnected'),
      ),
    ]);
    final adapter = _adapter(socket);

    await adapter.ensureInitialized();

    expect(socket.requests.single['op'], 'ping');
    expect(adapter.isReady, isTrue);
  });

  test('start sends the config and readStage reflects the daemon', () async {
    final socket = support.ScriptedHelperSocket([
      support.helperOk(support.helperStatusJson()),
      support.helperOk(support.helperStatusJson()),
    ]);
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
      support.ScriptedHelperSocket([
        support.helperOk(support.helperStatusJson(stage: 'connecting')),
      ]),
    );
    expect(await connecting.readStage(), VpnStage.connecting);

    final broken = _adapter(
      support.ScriptedHelperSocket([HelperTransportException('down')]),
    );
    expect(await broken.readStage(), isNull);
  });

  test(
    'readStage never reports a contract-violating stage as connected',
    () async {
      // A malformed/incompatible daemon that says `up: true` with an unknown
      // stage must read as unknown, not as a live tunnel.
      final adapter = _adapter(
        support.ScriptedHelperSocket([
          support.helperOk(support.helperStatusJson(stage: 'mystery')),
        ]),
      );
      expect(await adapter.readStage(), isNull);
    },
  );

  test('readTraffic reports counters while up, null while down', () async {
    final up = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(support.helperStatusJson(rxBytes: 100, txBytes: 200)),
      ]),
    );
    expect(await up.readTraffic(), {'rxBytes': 100, 'txBytes': 200});

    final down = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(
          support.helperStatusJson(up: false, stage: 'disconnected'),
        ),
      ]),
    );
    expect(await down.readTraffic(), isNull);
  });

  test('readHandshake converts epoch seconds and nulls a zero', () async {
    final handshook = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(support.helperStatusJson(lastHandshake: 1718000000)),
      ]),
    );
    expect(
      await handshook.readHandshake(),
      DateTime.fromMillisecondsSinceEpoch(1718000000 * 1000, isUtc: true),
    );

    final never = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(support.helperStatusJson()),
      ]),
    );
    expect(await never.readHandshake(), isNull);
  });

  test('getActivePeer returns the newest peer, null when empty', () async {
    final peer = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(
          support.helperStatusJson(
            publicKey: 'PUBKEY=',
            endpoint: '198.51.100.7:1234',
          ),
        ),
      ]),
    );
    final active = await peer.getActivePeer();
    expect(active, isNotNull);
    expect(active!.publicKey, 'PUBKEY=');
    expect(active.endpoint, '198.51.100.7:1234');

    final none = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(support.helperStatusJson()),
      ]),
    );
    expect(await none.getActivePeer(), isNull);
  });

  test('stop retries once and never throws', () async {
    final socket = support.ScriptedHelperSocket([
      HelperTransportException('first attempt failed'),
      support.helperOk(
        support.helperStatusJson(up: false, stage: 'disconnected'),
      ),
    ]);
    final adapter = _adapter(socket);

    await adapter.stop('test');

    expect(socket.requests.length, 2);
    expect(socket.requests.every((r) => r['op'] == 'down'), isTrue);
  });

  test('stop gives up quietly when both attempts fail', () async {
    final socket = support.ScriptedHelperSocket([
      HelperTransportException('first'),
      HelperTransportException('second'),
    ]);
    final adapter = _adapter(socket);

    await adapter.stop('test');

    expect(socket.requests.length, 2);
  });

  test('killGhost downs the tunnel and reports success', () async {
    final gone = _adapter(
      support.ScriptedHelperSocket([
        support.helperOk(
          support.helperStatusJson(up: false, stage: 'disconnected'),
        ),
      ]),
    );
    expect(await gone.killGhost(), isTrue);

    final broken = _adapter(
      support.ScriptedHelperSocket([HelperTransportException('down')]),
    );
    expect(await broken.killGhost(), isFalse);
  });

  test('helper adapter advertises handshake support with no push stages', () {
    final adapter = _adapter(support.ScriptedHelperSocket([]));
    expect(adapter.handshakeReaderSupported, isTrue);
    expect(adapter.stages, emitsDone);
  });
}
