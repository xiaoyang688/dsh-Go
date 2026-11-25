import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

void main() {
  test('0.6.7 sends only the bounded Go layout through the authenticated Bot route', () async {
    final server = await FakeRemoteServer.start();
    addTearDown(server.close);
    final host = await FakeRemoteHost.start(server);
    addTearDown(host.close);
    final account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    addTearDown(account.close);
    host.capabilities.add('plugin.route.v1');
    final requests = <Map<String, Object?>>[];
    final layout = DsBotGoLayout(revision: 0, folders: const [], bots: const [], rooms: const ['room']);
    host.pluginRoute = (params) async {
      requests.add(params);
      return {
        'status': 200,
        'json': {
          'ok': true,
          'value': {
            'goLayout': {...layout.toJson(), 'revision': 1},
          },
        },
      };
    };
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost((await account.listHosts()).single);
    final api = DsBotApi.of(client)!;
    expect((await api.setGoLayout(layout)).revision, 1);
    for (final payload in <Map<String, Object?>>[
      {},
      {'goLayout': layout.toJson(), 'locale': 'en'},
      {
        'goLayout': {...layout.toJson(), 'locale': 'en'},
      },
      {
        'goLayout': {
          ...layout.toJson(),
          'rooms': List.filled(1025, {'roomId': 'room', 'folderId': null}),
        },
      },
    ]) {
      await expectLater(
        api.call('set-prefs', payload),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
      );
    }
    expect(requests.single, {
      'route': 'api/bot',
      'body': {
        'endpoint': 'set-prefs',
        'payload': {'goLayout': layout.toJson()},
      },
    });
    expect(server.protocolErrors, isEmpty);
  });
}
