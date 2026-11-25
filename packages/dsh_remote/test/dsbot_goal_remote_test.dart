import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

void main() {
  test('0.6.7 forwards goal actions over the fixed authenticated route', () async {
    final server = await FakeRemoteServer.start();
    addTearDown(server.close);
    final host = await FakeRemoteHost.start(server);
    addTearDown(host.close);
    final account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    addTearDown(account.close);
    host.capabilities.add('plugin.route.v1');
    final requests = <Map<String, Object?>>[];
    host.pluginRoute = (params) async {
      requests.add(params);
      final endpoint = (params['body'] as Map)['endpoint'];
      return {
        'status': 200,
        'json': endpoint == 'goal-draft'
            ? {'ok': true, 'value': <String, Object?>{}}
            : {
                'ok': false,
                'error': {'code': 'bot/stale', 'message': 'The goal has changed. Look again.'},
              },
      };
    };
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost((await account.listHosts()).single);
    final api = DsBotApi.of(client)!;
    await api.draftRoomGoal('room', 'Release the guide');
    await expectLater(
      api.controlRoomGoal('room', 'goal-abc', DsBotGoalAction.pause, stopWork: true),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'bot/stale')),
    );
    await expectLater(
      api.call('goal-control', {'roomId': 'room', 'role': 'admin'}),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
    );
    expect(requests, [
      {
        'route': 'api/bot',
        'body': {
          'endpoint': 'goal-draft',
          'payload': {'roomId': 'room', 'text': 'Release the guide'},
        },
      },
      {
        'route': 'api/bot',
        'body': {
          'endpoint': 'goal-control',
          'payload': {'roomId': 'room', 'goalId': 'goal-abc', 'action': 'pause', 'stopWork': true},
        },
      },
    ]);
    expect(server.protocolErrors, isEmpty);
  });
}
