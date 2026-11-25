import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const legacy = {
  'revision': 12,
  'folders': [
    {'id': 'work', 'name': 'Work', 'parentId': null},
  ],
  'bots': [
    {'botId': 'bot-1', 'folderId': 'work'},
  ],
  'rooms': [
    {'roomId': 'room-1', 'folderId': null},
  ],
};

Map<String, Object?> row(Object? layout, int revision) => {
  'ns': 'dsh-go-layout',
  'value': {'goLayout': layout},
  'revision': revision,
  'autoGenerate': false,
};

class _Carrier extends DshCarrier {
  final calls = <(String, Map<String, Object?>)>[];
  late RpcResult Function(String, Map<String, Object?>) respond;

  @override
  String get kind => 'scripted';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    return respond(endpoint, args);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}

void main() {
  late _Carrier carrier;
  late GoLayoutApi api;
  setUp(() {
    carrier = _Carrier();
    api = GoLayoutApi(DshRpc(carrier));
  });

  test('absence, uninitialized and deliberately blank are distinct', () async {
    void describe(List<Object?> rows) {
      carrier.respond = (_, _) => RpcOk({'writable': true, 'hasDocument': true, 'namespaces': rows});
    }

    describe([]);
    expect(await api.describe(), isNull);
    describe([row(null, 0)]);
    expect((await api.describe())!.layout, isNull);
    describe([
      row({'revision': 0, 'folders': [], 'bots': [], 'rooms': []}, 1),
    ]);
    expect((await api.describe())!.layout?.folders, isEmpty);
    describe([
      row({'revision': 0}, 1),
    ]);
    await expectLater(api.describe(), throwsA(isA<DshProtocolException>()));
    carrier.respond = (_, _) => const RpcOk(null);
    await expectLater(api.describe(), throwsA(isA<DshProtocolException>()));
  });

  test('CAS uses descriptor revision and acknowledges the full migrated payload', () async {
    carrier.respond = (endpoint, _) => endpoint == 'settings/describe'
        ? RpcOk({
            'writable': true,
            'hasDocument': true,
            'namespaces': [row(null, 4)],
          })
        : RpcOk(row(legacy, 5));
    final observed = (await api.describe())!;
    final saved = await api.save(observed, DsBotGoLayout.parse(legacy)!);
    expect(saved.layout?.toJson(), legacy);
    expect(saved.revision, 5);
    expect(carrier.calls.map((call) => call.$1), ['settings/describe', 'settings/mutate']);
    expect(carrier.calls.first.$2, isEmpty);
    expect(carrier.calls.last.$2, {
      'ns': 'dsh-go-layout',
      'expectedRevision': 4,
      'ops': [
        {'op': 'set', 'path': ['goLayout'], 'value': legacy},
      ],
    });
  });

  test('conflict is propagated and a mismatched acknowledgement fails', () async {
    carrier.respond = (_, _) => RpcOk({
      'writable': true,
      'namespaces': [row(null, 0)],
    });
    final observed = (await api.describe())!;
    final source = DsBotGoLayout.parse(legacy)!;
    carrier.respond = (_, _) => RpcError(DshRemoteException('settings/conflict', 'stale revision'));
    await expectLater(
      api.save(observed, source),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'settings/conflict')),
    );
    carrier.respond = (_, _) => RpcOk(row({...legacy, 'rooms': []}, 1));
    await expectLater(api.save(observed, source), throwsA(isA<DshProtocolException>()));
  });
}
