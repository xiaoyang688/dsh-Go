import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  late final _rpc = _Rpc(carrier);

  @override
  _Rpc get rpc => _rpc;
}

class _Rpc extends DshRpc {
  _Rpc(super.carrier);

  final requests = <Map<String, Object?>>[];
  bool unavailable = false;

  @override
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}, Duration? timeout]) async {
    expect(endpoint, 'skills/list');
    requests.add(args);
    if (unavailable) throw const DshRemoteException('gateway/not-found', 'Unsupported');
    return {
      'skills': [
        {'name': 'release-notes', 'description': 'Draft a release note', 'modelInvocable': false},
        {'name': 'summarize', 'description': 'Summarize a document', 'modelInvocable': true},
      ],
    };
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, Widget page, FakeDsBotTransport bot, _Client client) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(
        home: page,
        brightness: Brightness.light,
        overrides: dsBotOverrides(bot, connection: HostConnection(client: client, isLocal: true)),
      ),
    );
    await frames(tester);
  }

  final skillsButton = find.byTooltip('技能');

  testWidgets('Host catalog uses the current part and a manual skill is sent as ordinary Bot text', (tester) async {
    final bot = FakeDsBotTransport(team: sampleTeam(working: false));
    final client = _Client();
    await open(tester, const BotChatPage(botId: 'm1'), bot, client);
    expect(client.rpc.requests, isEmpty);
    await tester.enterText(find.byType(TextField), 'for the new version');
    await tester.tap(skillsButton);
    await frames(tester);

    expect(client.rpc.requests, [
      {'request': {'sessionId': 'm1c'}},
    ]);
    expect(find.text('仅手动'), findsOneWidget);
    expect(find.text('Summarize a document'), findsOneWidget);
    await tester.tap(find.text('/release-notes'));
    await frames(tester);

    expect(bot.endpoints, isNot(contains('send')));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '/release-notes for the new version');
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    expect(bot.calls.where((call) => call.$1 == 'send').single.$2, {
      'sessionId': 'm1',
      'text': '/release-notes for the new version',
    });
  });

  testWidgets('unsupported catalog offers retry and keeps the draft intact', (tester) async {
    final bot = FakeDsBotTransport();
    final client = _Client()..rpc.unavailable = true;
    await open(tester, const BotChatPage(botId: 'b2'), bot, client);
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(skillsButton);
    await frames(tester);
    expect(find.text('没能读取技能'), findsOneWidget);

    client.rpc.unavailable = false;
    await tester.tap(find.text('重试'));
    await frames(tester);
    expect(client.rpc.requests, hasLength(2));
    expect(find.text('/summarize'), findsOneWidget);
    Navigator.of(tester.element(find.text('/summarize'))).pop();
    await frames(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    expect(bot.endpoints, isNot(contains('send')));
  });

  testWidgets('a picker opened on an earlier part cannot change the current draft', (tester) async {
    final team = sampleTeam(working: false);
    final bot = FakeDsBotTransport(team: team);
    final client = _Client();
    await open(tester, const BotChatPage(botId: 'm1'), bot, client);
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(skillsButton);
    await frames(tester);
    expect(find.text('/release-notes'), findsOneWidget);

    team['revision'] = 8;
    (team['bots']! as List).first['sessionId'] = 'm1-new';
    bot.emit('revision', {'revision': 8});
    await frames(tester);
    await tester.tap(find.text('/release-notes'));
    await frames(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    expect(bot.endpoints, isNot(contains('send')));
  });

  for (final surface in ['group', 'read-only', 'local agent']) {
    testWidgets('explicit picker is absent in $surface chat', (tester) async {
      final team = sampleTeam(working: false);
      if (surface == 'read-only') team['readOnly'] = 'Team is locked';
      if (surface == 'local agent') (team['bots']! as List).first['engine'] = 'codex';
      final page = surface == 'group' ? const RoomChatPage(roomId: 'r1') : const BotChatPage(botId: 'm1');
      final client = _Client();
      await open(tester, page, FakeDsBotTransport(team: team), client);
      expect(skillsButton, findsNothing);
      expect(client.rpc.requests, isEmpty);
    });
  }
}
