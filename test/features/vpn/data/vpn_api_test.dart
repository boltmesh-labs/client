import 'package:boltmesh/features/vpn/data/vpn_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> dialJson() => {
  'id': 'dev-1',
  'assigned_ip': '10.8.0.5',
  'server_id': 'srv-1',
  'server_name': 'srv one',
  'endpoint': '203.0.113.10',
  'wg_port': 51820,
  'wg_dns': '10.8.0.1',
  'wg_public_key': 'SRV',
};

/// Dio that captures the outgoing request and answers with canned data,
/// so no HTTP client or extra test dependency is needed.
Dio fakeDio(
  dynamic Function(RequestOptions options) responder, {
  List<RequestOptions>? seen,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        seen?.add(options);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: responder(options),
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('regions maps backend list', () async {
    final api = VpnApi(
      fakeDio(
        (_) => [
          {
            'id': 'r-1',
            'name': 'Region One',
            'country_code': 'DE',
            'servers': [
              {
                'id': 'srv-1',
                'name': 'srv one',
                'endpoint': '203.0.113.10',
                'wg_port': 51820,
                'wg_dns': '10.8.0.1',
                'active_peers': 3,
              },
            ],
          },
        ],
      ),
    );
    final regions = await api.regions();
    expect(regions, hasLength(1));
    expect(regions.single.countryCode, 'DE');
    expect(regions.single.servers.single.activePeers, 3);
  });

  test('provision sends idempotency key header and public key', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(fakeDio((_) => dialJson(), seen: seen));
    final dial = await api.provision(
      name: 'Phone',
      platform: 'android',
      publicKey: 'PUB',
      idempotencyKey: 'idem-1',
    );
    expect(dial.deviceId, 'dev-1');
    expect(seen.single.path, '/vpn-devices');
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    final body = seen.single.data as Map;
    expect(body['public_key'], 'PUB');
    expect(body['platform'], 'android');
  });

  test('config/disconnect hit device-scoped paths', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(fakeDio((_) => dialJson(), seen: seen));
    await api.config('dev-1');
    await api.disconnect('dev-1');
    expect(seen[0].path, '/vpn-devices/dev-1/config');
    expect(seen[1].path, '/vpn-devices/dev-1/disconnect');
  });

  test('switchServer requires exactly one target', () async {
    final api = VpnApi(fakeDio((_) => dialJson()));
    expect(
      () => api.switchServer(deviceId: 'dev-1', publicKey: 'PUB'),
      throwsArgumentError,
    );
    expect(
      () => api.switchServer(
        deviceId: 'dev-1',
        publicKey: 'PUB',
        serverId: 'srv-1',
        regionId: 'r-1',
      ),
      throwsArgumentError,
    );
  });

  test('switchServer posts the single target', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(fakeDio((_) => dialJson(), seen: seen));
    await api.switchServer(
      deviceId: 'dev-1',
      publicKey: 'PUB',
      serverId: 'srv-1',
    );
    expect(seen.single.path, '/vpn-devices/dev-1/switch');
    final body = seen.single.data as Map;
    expect(body['server_id'], 'srv-1');
    expect(body.containsKey('region_id'), isFalse);
  });

  test('rotateKeys posts the replacement public key', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(fakeDio((_) => dialJson(), seen: seen));
    final dial = await api.rotateKeys(deviceId: 'dev-1', publicKey: 'NEW-PUB');
    expect(dial.deviceId, 'dev-1');
    expect(seen.single.path, '/vpn-devices/dev-1/rotate-keys');
    final body = seen.single.data as Map;
    expect(body['public_key'], 'NEW-PUB');
  });

  test('status maps the backend heartbeat payload', () async {
    final api = VpnApi(
      fakeDio(
        (_) => {
          'device_id': 'dev-1',
          'status': 'suspended',
          'suspended_reason': 'subscription_lapsed',
          'tier': 'pro',
          'max_devices': 5,
          'active_devices': 2,
          'subscription_expires_at': '2026-01-01T00:00:00Z',
        },
      ),
    );
    final st = await api.status('dev-1');
    expect(st.isSuspended, isTrue);
    expect(st.suspendedReason, 'subscription_lapsed');
    expect(st.tier, 'pro');
    expect(st.maxDevices, 5);
    expect(st.activeDevices, 2);
    expect(st.subscriptionExpiresAt?.year, 2026);
  });

  test('revoke hits device delete path', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(fakeDio((_) => null, seen: seen));
    await api.revoke('dev-1');
    expect(seen.single.path, '/vpn-devices/dev-1');
    expect(seen.single.method, 'DELETE');
  });

  test('cancelToken is attached to cancellable requests', () async {
    final seen = <RequestOptions>[];
    final api = VpnApi(
      fakeDio(
        (o) => o.path.endsWith('/vpn-regions') ? <dynamic>[] : dialJson(),
        seen: seen,
      ),
    );
    final token = CancelToken();
    await api.config('dev-1', cancelToken: token);
    await api.connect(deviceId: 'dev-1', publicKey: 'PUB', cancelToken: token);
    await api.switchServer(
      deviceId: 'dev-1',
      publicKey: 'PUB',
      serverId: 'srv-1',
      cancelToken: token,
    );
    await api.rotateKeys(
      deviceId: 'dev-1',
      publicKey: 'PUB',
      cancelToken: token,
    );
    await api.regions(cancelToken: token);
    expect(seen, hasLength(5));
    expect(seen.every((o) => identical(o.cancelToken, token)), isTrue);
  });
}
