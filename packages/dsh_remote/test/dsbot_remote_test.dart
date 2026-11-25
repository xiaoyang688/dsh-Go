import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

const _capability = 'ds-bot.remote.v1';
const _options = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);
Matcher _error(String code) => isA<DshRemoteException>().having((e) => e.code, 'code', code);

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
  });

  tearDown(() async {
    expect(server.protocolErrors, isEmpty);
    await account.close();
    await host.close();
    await server.close();
  });

  Future<DshClient> connect() async {
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    return account.connectHost((await account.listHosts()).single, muxOptions: _options);
  }

  test('negotiates DS Bot over the exact tunnel call and feed methods', () async {
    host.capabilities.addAll([_capability, 'plugin.route.v1']);
    host.handlers['dsBot/call'] = (args) => {
      'ok': true,
      'value': switch (args['endpoint']) {
        'hello' => {
          'ok': true,
          'value': {'api': 1, 'boot': 'fixture'},
        },
        _ => {
          'ok': false,
          'error': {'code': 'bot/read-only', 'message': 'Read only'},
        },
      },
    };
    final opened = Completer<FakeHostStream>();
    host.onOpen = (stream) {
      expect(stream.endpoint, 'dsBot/feed');
      expect(stream.payload, {'args': <String, Object?>{}});
      opened.complete(stream);
      stream.push({
        'event': 'hello',
        'data': {'boot': 'fixture', 'seq': 2},
      });
    };

    final client = await connect();
    final api = DsBotApi.of(client)!;
    final hello = await api.hello(version: 'fixture');
    expect(hello.boot, 'fixture');
    expect(host.calls.single.$1, 'dsBot/call');
    expect(host.calls.single.$2, {
      'endpoint': 'hello',
      'payload': {
        'client': {'name': 'dsh-go', 'version': 'fixture', 'platform': 'android'},
        'api': [1],
      },
    });
    await expectLater(api.send('fixture-bot', 'hello'), throwsA(_error('bot/read-only')));
    expect(host.calls.last.$1, 'dsBot/call');
    expect(host.calls.last.$2, {
      'endpoint': 'send',
      'payload': {'sessionId': 'fixture-bot', 'text': 'hello'},
    });
    final events = StreamIterator(api.transport.openFeed());
    addTearDown(events.cancel);
    expect(await events.moveNext(), isTrue);
    expect(events.current.event, 'hello');
    expect(events.current.data, {'boot': 'fixture', 'seq': 2});
    final stream = await opened.future;
    final next = events.moveNext();
    stream.push({
      'event': 'revision',
      'data': {'revision': 4},
    });
    expect(await next, isTrue);
    expect(events.current.event, 'revision');
    await events.cancel();
    await pumpEventQueue();
    expect(stream.closed, isTrue);
  });

  test('fresh sessions determine availability and unrelated routes stay closed', () async {
    final client = await connect();
    final carrier = client.carrier as RemoteTunnelCarrier;
    Future<void> reconnect() async {
      carrier.reconnect();
      await client.mux.ready();
    }

    Future<void> expectRefused() async {
      expect(DsBotApi.of(client), isNull);
      final transport = DsBotRpcTransport(client);
      await expectLater(transport.call('hello', const {}), throwsA(_error('METHOD_NOT_ALLOWED')));
      await expectLater(transport.openFeed(), emitsError(_error('METHOD_NOT_ALLOWED')));
    }

    await expectRefused();
    host.capabilities.add(_capability);
    await reconnect();
    expect(DsBotApi.of(client), isNotNull);
    for (final endpoint in ['dsBot/other', 'bot', 'bot/feed', 'dsbot/call']) {
      await expectLater(client.rpc.call(endpoint), throwsA(_error('METHOD_NOT_ALLOWED')));
    }
    host.capabilities.remove(_capability);
    await reconnect();
    await expectRefused();
    expect(host.calls.where((call) => call.$1.startsWith('dsBot/')), isEmpty);
    expect(host.openedStreamParams.where((p) => p['endpoint'] == 'dsBot/feed'), isEmpty);
  });

  test('0.6.7 uses the exact unary api/bot route on the authenticated connection', () async {
    host.capabilities.add('plugin.route.v1');
    final requests = <Map<String, Object?>>[];
    host.pluginRoute = (params) async {
      requests.add(params);
      return {
        'status': 200,
        'json': {
          'ok': true,
          'value': {'api': 1, 'boot': 'legacy'},
        },
      };
    };
    final client = await connect();
    final api = DsBotApi.of(client)!;
    expect(api.transport, isA<DsBotUnaryTransport>());
    expect((await api.hello()).boot, 'legacy');
    expect(requests.single, {
      'route': 'api/bot',
      'body': {
        'endpoint': 'hello',
        'payload': {
          'client': {'name': 'dsh-go', 'platform': 'android'},
          'api': [1],
        },
      },
    });
    for (final operation in ['phone-set', 'file-text', 'provider-key', 'computer-takeover', 'plugin.route.call']) {
      await expectLater(api.call(operation), throwsA(_error('METHOD_NOT_ALLOWED')));
    }
    await expectLater(
      api.call('update-bot', {'id': 'bot', 'permissions': 'all'}),
      throwsA(_error('METHOD_NOT_ALLOWED')),
    );
    await expectLater(api.setRoomRelayLimit('room', 20), throwsA(_error('METHOD_NOT_ALLOWED')));
    await expectLater(client.rpc.call('plugin.route.call'), throwsA(_error('METHOD_NOT_ALLOWED')));
    await expectLater(api.transport.openFeed(), emitsError(_error('FEATURE_NOT_SUPPORTED')));
    expect(requests, hasLength(1));
    expect(host.openedStreamParams.map((p) => p['endpoint']), [r'$events']);

    (client.carrier as RemoteTunnelCarrier).reconnect();
    await client.mux.ready();
    await expectLater(api.send('bot', 'stale'), throwsA(isA<DshTransportException>()));
    expect(requests, hasLength(1));
    expect(await DsBotApi.of(client)!.hello(), isA<DsBotHello>());
    expect(requests, hasLength(2));
  });

  test('the unary route transports staged photos and restricts their payload fields', () async {
    host.capabilities.add('plugin.route.v1');
    final requests = <Map<String, Object?>>[];
    host.pluginRoute = (params) async {
      requests.add(params);
      return {
        'status': 200,
        'json': {
          'ok': true,
          'value': {'id': 'photo'},
        },
      };
    };
    final api = DsBotApi.of(await connect())!;
    final id = await api.stageImage('image/png', [1, 2, 3]);
    expect(id, 'photo');
    await api.send('bot', '', images: [id]);
    await expectLater(api.call('stage-image', {'path': '/tmp/photo.png'}), throwsA(_error('METHOD_NOT_ALLOWED')));
    expect(requests, [
      {
        'route': 'api/bot',
        'body': {
          'endpoint': 'stage-image',
          'payload': {'mediaType': 'image/png', 'data': 'AQID'},
        },
      },
      {
        'route': 'api/bot',
        'body': {
          'endpoint': 'send',
          'payload': {
            'sessionId': 'bot',
            'text': '',
            'images': ['photo'],
          },
        },
      },
    ]);
  });

  test('the unary route reads only referenced Bot attachments', () async {
    host.capabilities.add('plugin.route.v1');
    final requests = <Map<String, Object?>>[];
    host.pluginRoute = (params) async {
      requests.add(params);
      return {
        'status': 200,
        'json': {
          'ok': true,
          'value': {'mime': 'image/png', 'data': 'AQID'},
        },
      };
    };
    final api = DsBotApi.of(await connect())!;
    expect(await api.image('room', 'attachment', preview: true), [1, 2, 3]);
    await expectLater(api.call('image', {'path': '/tmp/photo.png'}), throwsA(_error('METHOD_NOT_ALLOWED')));
    await expectLater(api.call('markdown-image', {'sessionId': 'room', 'path': 'photo.png'}),
      throwsA(_error('METHOD_NOT_ALLOWED')));
    await expectLater(api.call('file-download', {'sessionId': 'room', 'attachmentId': 'attachment'}),
      throwsA(_error('METHOD_NOT_ALLOWED')));
    expect(requests.single, {
      'route': 'api/bot',
      'body': {
        'endpoint': 'image',
        'payload': {'sessionId': 'room', 'attachmentId': 'attachment', 'preview': true},
      },
    });
  });

  test('the unary route preserves HTTP, Bot and tunnel errors without replay', () async {
    host.capabilities.add('plugin.route.v1');
    final client = await connect();
    final api = DsBotApi.of(client)!;
    await expectLater(api.hello(), throwsA(_error('FEATURE_NOT_SUPPORTED')));
    host.pluginRoute = (_) async => {'status': 404, 'json': null};
    await expectLater(api.hello(), throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 404)));
    host.pluginRoute = (_) async => {
      'status': 200,
      'json': {
        'ok': false,
        'error': {'code': 'bot/read-only', 'message': 'Read only'},
      },
    };
    await expectLater(api.send('bot', 'message'), throwsA(_error('bot/read-only')));
    host.pluginRoute = (_) async => {'status': 200, 'json': 'not JSON'};
    await expectLater(api.hello(), throwsA(isA<DshProtocolException>()));

    host.directResponseLimit = 1024;
    var mutations = 0;
    host.pluginRoute = (params) async {
      expect((params['body'] as Map)['endpoint'], 'send');
      mutations++;
      return {
        'status': 200,
        'json': {'ok': true, 'value': 'x' * 2048},
      };
    };
    await expectLater(api.send('bot', 'message'), throwsA(_error('RESPONSE_TOO_LARGE')));
    expect(mutations, 1);
    expect(host.rpcMethods.where((method) => method.startsWith('harness.remote.transfer.')), isEmpty);

    final delivered = Completer<void>();
    final lateReply = Completer<Object?>();
    host.pluginRoute = (params) async {
      expect((params['body'] as Map)['endpoint'], 'send');
      mutations++;
      delivered.complete();
      return lateReply.future;
    };
    final pending = api.call('send', {'sessionId': 'bot', 'text': 'message'}, const Duration(milliseconds: 100));
    final result = expectLater(pending, throwsA(isA<DshTransportException>()));
    await delivered.future;
    await result;
    lateReply.complete({
      'status': 200,
      'json': {'ok': true},
    });
    await pumpEventQueue();
    expect(mutations, 2);
    expect(host.rpcMethods.where((method) => method.startsWith('harness.remote.transfer.')), isEmpty);
  });

  test('an oversized DS Bot mutation result never triggers a replay', () async {
    host.capabilities.add(_capability);
    host.directResponseLimit = 1024;
    var calls = 0;
    host.handlers['dsBot/call'] = (args) {
      expect(args['endpoint'], 'send');
      calls++;
      return {
        'ok': true,
        'value': {'ok': true, 'value': 'x' * 2048},
      };
    };
    final client = await connect();
    await expectLater(DsBotApi.of(client)!.send('bot', 'hello'), throwsA(_error('RESPONSE_TOO_LARGE')));
    expect(calls, 1);
    expect(host.rpcMethods.where((method) => method.startsWith('harness.remote.transfer.')), isEmpty);
  });
}
