import 'package:boltmesh/core/mutex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unlocked acquire completes synchronously and locks', () async {
    final m = AsyncMutex();
    expect(m.isLocked, isFalse);
    var sync = false;
    final f = m.acquire().then((_) => sync = true);
    expect(m.isLocked, isTrue);
    await f;
    expect(sync, isTrue);
  });

  test('second acquirer waits for release, FIFO order', () async {
    final m = AsyncMutex();
    final order = <String>[];
    final releaseA = await m.acquire('a');
    var bReady = false;
    final bFuture = m.acquire('b').then((releaseB) {
      bReady = true;
      order.add('b');
      releaseB();
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bReady, isFalse);
    expect(m.isLocked, isTrue);
    order.add('a');
    releaseA();
    await bFuture;
    expect(order, ['a', 'b']);
    expect(m.isLocked, isFalse);
  });

  test('release is idempotent and frees the tail', () async {
    final m = AsyncMutex();
    final release = await m.acquire();
    release();
    release();
    expect(m.isLocked, isFalse);
    final release2 = await m.acquire();
    expect(m.isLocked, isTrue);
    release2();
    expect(m.isLocked, isFalse);
  });

  test('queued disconnect still runs after connect', () async {
    final m = AsyncMutex();
    final ran = <String>[];
    final releaseConnect = await m.acquire('connect');
    final disconnect = m.acquire('disconnect').then((release) async {
      ran.add('disconnect');
      release();
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ran.add('connect-done');
    releaseConnect();
    await disconnect;
    expect(ran, ['connect-done', 'disconnect']);
  });
}
