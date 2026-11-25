import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const layoutJson = {
  'revision': 3,
  'folders': [
    {'id': 'project', 'name': 'Projects', 'parentId': null},
    {'id': 'release', 'name': 'Releases', 'parentId': 'project'},
  ],
  'bots': [
    {'botId': 'coordinator', 'folderId': 'release'},
    {'botId': 'editor', 'folderId': null},
  ],
  'rooms': [
    {'roomId': 'later', 'folderId': null},
    {'roomId': 'earlier', 'folderId': null},
  ],
};

class _Transport implements DsBotTransport {
  final calls = <(String, Map<String, Object?>)>[];
  Object? response;

  @override
  Future<Object?> call(String endpoint, Map<String, Object?> payload, {Duration? timeout}) async {
    calls.add((endpoint, payload));
    return response;
  }

  @override
  Future<void> close() async {}

  @override
  Stream<DsBotSseEvent> openFeed() => const Stream.empty();
}

void main() {
  test('team layout is optional and preserves the host sibling order', () {
    expect(
      DsBotTeam.fromJson({
        'prefs': {'legacy': true},
      }).goLayout,
      isNull,
    );
    final team = DsBotTeam.fromJson({
      'prefs': {'goLayout': layoutJson},
    });
    expect(team.goLayout!.toJson(), layoutJson);
    expect(team.goLayout!.rooms, ['later', 'earlier']);
  });

  test('rejects cyclic trees, unknown parents, unbounded lists, and foreign write fields', () {
    Map<String, Object?> folder(String id, String? parentId) => {'id': id, 'name': id, 'parentId': parentId};
    for (final invalid in [
      {
        ...layoutJson,
        'folders': [folder('a', 'b'), folder('b', 'a')],
      },
      {
        ...layoutJson,
        'folders': [folder('a', 'missing')],
      },
      {
        ...layoutJson,
        'rooms': List.filled(1025, {'roomId': 'room', 'folderId': null}),
      },
      {
        ...layoutJson,
        'rooms': [
          {'roomId': 'room', 'folderId': 'project'},
        ],
      },
      {
        ...layoutJson,
        'bots': [
          {'botId': 'bot', 'folderId': 'project', 'role': 'admin'},
        ],
      },
      {...layoutJson, 'otherSetting': true},
    ]) {
      expect(DsBotGoLayout.parse(invalid, exact: true), isNull);
    }
  });

  test('writes only the Go layout and requires the next layout revision from the host', () async {
    final transport = _Transport();
    final api = DsBotApi(transport);
    final layout = DsBotGoLayout.parse(layoutJson)!;
    transport.response = {'locale': 'en'};
    await expectLater(api.setGoLayout(layout), throwsA(isA<DshProtocolException>()));
    expect(transport.calls.single.$1, 'set-prefs');
    expect(transport.calls.single.$2, {'goLayout': layoutJson});
    transport.response = {'goLayout': layoutJson};
    await expectLater(api.setGoLayout(layout), throwsA(isA<DshProtocolException>()));
    transport.response = {
      'goLayout': {...layoutJson, 'revision': 4},
    };
    expect((await api.setGoLayout(layout)).revision, 4);
  });
}
