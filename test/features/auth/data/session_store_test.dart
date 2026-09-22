import 'package:boltmesh/features/auth/data/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/secure_storage.dart';

void main() {
  test('setAuth stores the whole session in one entry', () async {
    final storage = MapSecureStorage();
    final store = SessionStore(storage);
    final expiry = DateTime.utc(2026, 6);
    await store.setAuth(
      accessToken: 'access-1',
      expiresAt: expiry,
      refreshToken: 'refresh-1',
      username: 'octocat',
    );
    expect(storage.values.keys, [SessionStore.sessionKey]);
    expect(await store.apiToken(), 'access-1');
    expect(await store.refreshToken(), 'refresh-1');
    expect(await store.accessExpiry(), expiry);
    expect(await store.authUsername(), 'octocat');
  });

  test('setAuth replaces the session and clears omitted fields', () async {
    final store = SessionStore(MapSecureStorage());
    await store.setAuth(
      accessToken: 'a1',
      expiresAt: DateTime.utc(2026),
      refreshToken: 'r1',
      username: 'u1',
    );
    await store.setAuth(accessToken: 'a2', expiresAt: DateTime.utc(2026, 2, 2));
    expect(await store.apiToken(), 'a2');
    expect(await store.refreshToken(), isNull);
    expect(await store.authUsername(), isNull);
  });

  test('clearAuth drops the session', () async {
    final store = SessionStore(MapSecureStorage());
    await store.setAuth(accessToken: 'a', expiresAt: DateTime.utc(2026));
    await store.clearAuth();
    expect(await store.apiToken(), isNull);
    expect(await store.refreshToken(), isNull);
    expect(await store.accessExpiry(), isNull);
    expect(await store.authUsername(), isNull);
  });

  test('a corrupt session entry reads as empty', () async {
    final store = SessionStore(
      MapSecureStorage({SessionStore.sessionKey: 'nope'}),
    );
    expect(await store.apiToken(), isNull);
    expect(await store.accessExpiry(), isNull);
  });

  test('expiry round-trips as UTC with millisecond precision', () async {
    final store = SessionStore(MapSecureStorage());
    final expiry = DateTime.utc(2026, 6, 1, 12, 30, 45, 123);
    await store.setAuth(accessToken: 'a', expiresAt: expiry);
    final read = await store.accessExpiry();
    expect(read, expiry);
    expect(read!.isUtc, isTrue);
  });

  test('a session with wrongly-typed fields reads as empty', () async {
    final store = SessionStore(
      MapSecureStorage({
        SessionStore.sessionKey: '{"access": 5, "expiry_ms": "x"}',
      }),
    );
    expect(await store.apiToken(), isNull);
    expect(await store.accessExpiry(), isNull);
  });
}
