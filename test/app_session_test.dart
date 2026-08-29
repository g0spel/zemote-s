import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/zemote_client.dart';
import 'package:zemote/state/account_store.dart';
import 'package:zemote/state/app_session.dart';

String _url(String sid) =>
    'https://zcode.z.ai/remote/v4?sid=$sid&hash=h&t=1&name=D$sid';

Account _account(String sid) =>
    Account(id: 'acc-$sid', label: 'D$sid', url: _url(sid), addedAt: 0);

/// Fake [ZemoteClient]: no sockets. [gate] (when uncompleted) holds
/// connect() open so tests can stage mid-flight disconnects.
class _FakeClient extends ZemoteClient {
  final Completer<void> connectGate;
  bool disposed = false;

  _FakeClient(super.params, {Completer<void>? gate})
      : connectGate = gate ?? (Completer<void>()..complete());

  @override
  Future<void> connect() => connectGate.future;

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  test('connect 途中 disconnect:完成后不入连接池、不抢激活、客户端被释放', () async {
    final gate = Completer<void>();
    late _FakeClient created;
    final session = AppSession(
      clientFactory: (params, onLog) => created = _FakeClient(params, gate: gate),
    );
    final account = _account('a');

    final connecting = session.connect(account);
    await session.disconnect(account.id); // 途中撤销连接意图
    gate.complete(); // connect 此刻才完成

    await expectLater(connecting, throwsA(isA<StateError>()));
    expect(session.isConnected(account.id), isFalse); // 不入池
    expect(session.current, isNull); // 不抢激活
    expect(session.connecting(account.id), isFalse);
    expect(created.disposed, isTrue); // 在途连接作废而非泄漏
    expect(session.errorOf(account.id), isNull); // 主动取消不算连接失败
  });

  test('connect 途中 disconnect:另一台已激活设备不被在途连接夺走', () async {
    final gateA = Completer<void>();
    final clients = <String, _FakeClient>{};
    final session = AppSession(
      clientFactory: (params, onLog) => clients[params.deviceSid] =
          _FakeClient(params, gate: params.deviceSid == 'a' ? gateA : null),
    );
    final a = _account('a');
    final b = _account('b');

    final connectingA = session.connect(a);
    await session.switchTo(b); // B 立即连上并激活
    expect(session.current?.id, b.id);
    await session.disconnect(a.id); // 撤销 A 的在途连接
    gateA.complete();

    await expectLater(connectingA, throwsA(isA<StateError>()));
    expect(session.isConnected(a.id), isFalse); // A 不借在途 connect 复活
    expect(session.current?.id, b.id); // 激活态仍是 B
  });

  test('同账号在途 connect 复用同一 future:底层只建连一次', () async {
    final gate = Completer<void>();
    var created = 0;
    final session = AppSession(
      clientFactory: (params, onLog) {
        created++;
        return _FakeClient(params, gate: gate);
      },
    );
    final account = _account('a');

    final f1 = session.connect(account);
    final f2 = session.connect(account); // 在途:不得二次发起
    gate.complete();
    final (c1, c2) = await (f1, f2).wait;

    expect(created, 1); // factory 只建一个客户端
    expect(identical(c1, c2), isTrue);
    expect(session.isConnected(account.id), isTrue);

    // 连接完成后第三次调用:复用池内连接,仍不重建。
    final c3 = await session.connect(account);
    expect(created, 1);
    expect(identical(c3, c1), isTrue);
  });

  test('在途 connect 失败后复用方收到同一错误,且后续可重新发起', () async {
    var created = 0;
    final session = AppSession(clientFactory: (params, onLog) {
      created++;
      return _FailingClient(params);
    });
    final account = _account('a');

    final f1 = session.connect(account);
    final f2 = session.connect(account);
    await expectLater(f1, throwsA(isA<StateError>()));
    await expectLater(f2, throwsA(isA<StateError>()));
    expect(created, 1);
    expect(session.errorOf(account.id), isNotNull);
    expect(session.connecting(account.id), isFalse);

    // 失败清场后可重试(不残留在途 future)。
    final f3 = session.connect(account);
    await expectLater(f3, throwsA(isA<StateError>()));
    expect(created, 2);
  });
}

class _FailingClient extends ZemoteClient {
  _FailingClient(super.params);

  @override
  Future<void> connect() => throw StateError('relay-unavailable: down');

  @override
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) =>
      Future.value();

  @override
  Future<void> dispose() async {}
}
