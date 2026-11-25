import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final entry = find.byKey(const ValueKey('room-goal'));
  final input = find.byKey(const ValueKey('room-goal-brief'));
  final send = find.text('发送目标请求');
  Finder action(String name) => find.byKey(ValueKey('room-goal-$name'));

  Future<({FakeDsBotTransport fake, Map room, Map<String, Object?> team})> mount(
    WidgetTester tester, {
    String version = '0.3.10',
    Map<String, Object?>? goal,
    bool readOnly = false,
  }) async {
    usePhoneView(tester);
    final team = sampleTeam(working: false);
    final room = (team['rooms'] as List).first as Map;
    if (goal != null) room['goal'] = goal;
    if (readOnly) team['readOnly'] = 'Another host owns the data';
    final fake = FakeDsBotTransport(team: team)..helloOnFeed = false;
    fake.handlers['hello'] = (_) => {
      ...fake.helloAnswer(),
      'plugin': {'version': version},
    };
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: dsBotOverrides(fake),
        home: const RoomDetailsPage(roomId: 'r1'),
      ),
    );
    await tester.pumpAndSettle();
    return (fake: fake, room: room, team: team);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.scrollUntilVisible(entry, 180, scrollable: find.byType(Scrollable).first);
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  testWidgets('drafts via the goal route and cancels the resulting host draft', (tester) async {
    final h = await mount(tester);
    h.fake.handlers['goal-draft'] = (args) {
      h.room['goal'] = {'id': 'g1', 'status': 'drafting', 'brief': args['text']};
      h.team['revision'] = 8;
      return h.team;
    };
    h.fake.handlers['goal-control'] = (_) {
      h.room.remove('goal');
      h.team['revision'] = 9;
      return h.team;
    };
    await open(tester);
    expect(tester.widget<FilledButton>(find.ancestor(of: send, matching: find.byType(FilledButton))).onPressed, isNull);
    await tester.enterText(input, '  Draft a release checklist  ');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(h.fake.calls.lastWhere((c) => c.$1 == 'goal-draft').$2, {
      'roomId': 'r1',
      'text': 'Draft a release checklist',
    });
    expect(find.text('拟定中'), findsWidgets);
    expect(find.text('Draft a release checklist'), findsWidgets);
    await tester.tap(action('clear'));
    await tester.pumpAndSettle();
    expect(h.fake.calls.lastWhere((c) => c.$1 == 'goal-control').$2, {
      'roomId': 'r1',
      'goalId': 'g1',
      'action': 'clear',
    });
    expect(input, findsOneWidget);
  });

  testWidgets('renders stages and follows pause, resume, and confirmed stop from the host', (tester) async {
    final h = await mount(
      tester,
      goal: {
        'id': 'g2',
        'status': 'active',
        'title': 'Ship the guide',
        'acceptance': 'Review is complete',
        'current': 0,
        'stages': [
          {
            'title': 'Write draft',
            'acceptance': 'Outline reviewed',
            'tasks': [
              {'botId': 'b2', 'task': 'Prepare outline', 'status': 'working'},
            ],
          },
        ],
      },
    );
    h.fake.handlers['goal-control'] = (args) {
      final goal = h.room['goal'] as Map;
      goal['status'] = switch (args['action']) {
        'pause' => 'paused',
        'resume' => 'active',
        _ => 'stopped',
      };
      h.team['revision'] = (h.team['revision'] as int) + 1;
      return h.team;
    };
    await open(tester);
    expect(find.text('1. Write draft'), findsOneWidget);
    expect(find.text('Prepare outline'), findsOneWidget);
    for (final operation in ['pause', 'resume']) {
      await tester.ensureVisible(action(operation));
      await tester.tap(action(operation));
      await tester.pumpAndSettle();
      expect(h.fake.calls.lastWhere((c) => c.$1 == 'goal-control').$2, {
        'roomId': 'r1',
        'goalId': 'g2',
        'action': operation,
      });
    }
    await tester.ensureVisible(action('stop'));
    await tester.tap(action('stop'));
    await tester.pumpAndSettle();
    expect(h.fake.endpoints.where((e) => e == 'goal-control'), hasLength(2));
    await tester.tap(find.widgetWithText(FilledButton, '停止目标'));
    await tester.pumpAndSettle();
    expect(h.fake.calls.lastWhere((c) => c.$1 == 'goal-control').$2, {
      'roomId': 'r1',
      'goalId': 'g2',
      'action': 'stop',
    });
    expect(action('clear'), findsOneWidget);
  });

  testWidgets('preserves a failed draft and shows a localized error', (tester) async {
    final h = await mount(tester);
    h.fake.handlers['goal-draft'] = (_) => throw const DshRemoteException('bot/refused', 'Host refused the draft');
    await open(tester);
    await tester.enterText(input, 'Keep this text');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text(appL10n.stateBotOperationFailed), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, 'Keep this text');
  });

  testWidgets('shows goal details on a read-only host without controls', (tester) async {
    await mount(tester, readOnly: true, goal: {'id': 'g1', 'status': 'active', 'title': 'Read this goal'});
    await open(tester);
    expect(find.text('Read this goal'), findsWidgets);
    expect(action('pause'), findsNothing);
    expect(action('stop'), findsNothing);
  });

  testWidgets('older hosts without goal support keep existing room settings', (tester) async {
    await mount(tester, version: '0.2.0');
    expect(entry, findsNothing);
  });
}
