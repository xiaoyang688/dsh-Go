import 'dart:async';

import 'package:dsh_app/state/bot_layout_state.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

const _blank = {'revision': 0, 'folders': [], 'bots': [], 'rooms': []};
const _legacy = {
  'revision': 9,
  'folders': [
    {'id': 'work', 'name': 'Legacy work', 'parentId': null},
  ],
  'bots': [
    {'botId': 'b2', 'folderId': 'work'},
  ],
  'rooms': [],
};
const _copy = '复制 DS Bot 布局';
const _copied = '已将布局复制到 DSH Go Layout。现在可以恢复官方 DS Bot。';

class _LayoutHost extends DshCarrier {
  Object? layout;
  int revision = 0;
  int writes = 0;
  bool malformed = false;
  bool race = false;
  Completer<void>? beforeDescribe;
  bool loseReadback = false;
  bool _lost = false;

  Map<String, Object?> get row => {
    'ns': 'dsh-go-layout',
    'revision': revision,
    'value': {'goLayout': layout},
  };

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'settings/describe') {
      if (beforeDescribe case final gate?) await gate.future;
      if (loseReadback && writes > 0 && !_lost) {
        _lost = true;
        throw const DshProtocolException('Fixture lost the first readback');
      }
      return RpcOk({
        'writable': true,
        'hasDocument': true,
        'namespaces': [
          malformed ? {'ns': 'dsh-go-layout'} : row,
        ],
      });
    }
    expect(endpoint, 'settings/mutate');
    writes++;
    expect(args['ns'], 'dsh-go-layout');
    expect(args['expectedRevision'], revision);
    if (race) {
      layout = _blank;
      revision++;
      return RpcError(DshRemoteException('settings/conflict', 'stale'));
    }
    final op = (args['ops'] as List).single as Map;
    expect(op['path'], ['goLayout']);
    layout = op['value'];
    revision++;
    return RpcOk(row);
  }

  @override
  String get kind => 'layout-test';
  @override
  DshTracer? get tracer => null;
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}

class _ActiveHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  @override
  void select(HostRef host) => state = host;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeDsBotTransport> open(WidgetTester tester, _LayoutHost host, {bool legacy = true}) async {
    usePhoneView(tester);
    final bots = FakeDsBotTransport(
      team: {
        ...sampleTeam(),
        if (legacy) 'prefs': {'goLayout': _legacy},
      },
    );
    await tester.pumpWidget(
      goldenApp(
        home: const BotsPage(),
        brightness: Brightness.light,
        overrides: dsBotOverrides(bots, layoutApi: GoLayoutApi(DshRpc(host))),
      ),
    );
    await tester.pumpAndSettle();
    return bots;
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('copies complete legacy layout after an explicit action and verifies interrupted readback', (
    tester,
  ) async {
    final host = _LayoutHost()..loseReadback = true;
    final bot = await open(tester, host);
    expect(find.text('Legacy work'), findsOneWidget);
    expect(host.writes, 0);
    await tap(tester, _copy);
    expect(host.layout, _legacy);
    expect(host.writes, 1);
    expect(bot.endpoints, isNot(contains('set-prefs')));
    expect(find.text(_copied), findsOneWidget);
    expect(find.text(_copy), findsNothing);
  });

  testWidgets('a saved blank independent layout wins over legacy data', (tester) async {
    final host = _LayoutHost()..layout = _blank;
    await open(tester, host);
    expect(find.text('Legacy work'), findsNothing);
    expect(find.text(_copy), findsNothing);
    expect(tester.widget<ListPageRow>(find.widgetWithText(ListPageRow, '编辑组织')).onTap, isNotNull);
    expect(host.writes, 0);
  });

  testWidgets('a malformed namespace preserves legacy display but blocks legacy writes', (tester) async {
    final host = _LayoutHost()..malformed = true;
    final bot = await open(tester, host);
    expect(find.text('Legacy work'), findsOneWidget);
    expect(tester.widget<ListPageRow>(find.widgetWithText(ListPageRow, '编辑组织')).onTap, isNull);
    expect(host.writes, 0);
    expect(bot.endpoints, isNot(contains('set-prefs')));
  });

  testWidgets('switching hosts during copy preflight cannot write to either host', (tester) async {
    usePhoneView(tester);
    final localHost = _LayoutHost();
    final remoteHost = _LayoutHost();
    final local = DshClient.withCarrier(localHost);
    final remote = DshClient.withCarrier(remoteHost);
    final team = {
      ...sampleTeam(),
      'prefs': {'goLayout': _legacy},
    };
    final localBot = FakeDsBotTransport(team: team);
    final remoteBot = FakeDsBotTransport(team: team);
    await tester.pumpWidget(
      goldenApp(
        home: const BotsPage(),
        brightness: Brightness.light,
        overrides: [
          activeHostProvider.overrideWith(_ActiveHost.new),
          activeConnectionProvider.overrideWith((ref) {
            final selected = ref.watch(activeHostProvider);
            return AsyncData(
              HostConnection(
                client: selected.isLocal ? local : remote,
                isLocal: selected.isLocal,
                kind: selected.kind,
                hostId: selected.id,
              ),
            );
          }),
          dsBotApiFactoryProvider.overrideWithValue((conn) => DsBotApi(conn.isLocal ? localBot : remoteBot)),
          goLayoutApiProvider.overrideWithValue((client) => GoLayoutApi(client.rpc)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final row = find.text(_copy);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final preflight = localHost.beforeDescribe = Completer<void>();
    await tester.tap(row);
    await tester.pump();
    final ref = ProviderScope.containerOf(tester.element(find.byType(BotsPage)));
    ref.read(activeHostProvider.notifier).select(const HostRef.ssh('another-host'));
    await tester.pumpAndSettle();
    preflight.complete();
    await tester.pumpAndSettle();
    expect(localHost.writes, 0);
    expect(remoteHost.writes, 0);
    expect(find.text(_copied), findsNothing);
    expect(find.text(_copy), findsOneWidget);
  });

  testWidgets('a concurrent first write triggers conflict without retry or legacy writes', (tester) async {
    final host = _LayoutHost()..race = true;
    final bot = await open(tester, host);
    await tap(tester, _copy);
    expect(host.writes, 1);
    expect(host.layout, _blank);
    expect(bot.endpoints, isNot(contains('set-prefs')));
    expect(find.textContaining('主机上的组织已变更'), findsOneWidget);
    expect(find.text(_copied), findsNothing);
  });
}
