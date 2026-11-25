import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show usePhoneView;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Finder _handle(String title) => find.descendant(
  of: find.widgetWithText(ListPageRow, title),
  matching: find.byType(ReorderableDelayedDragStartListener),
);

Future<void> _drag(WidgetTester tester, String from, String to) async {
  final source = _handle(from);
  await tester.ensureVisible(source);
  await tester.pumpAndSettle();
  final start = tester.getCenter(source);
  final end = tester.getCenter(_handle(to));
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 550));
  for (var i = 1; i <= 6; i++) {
    await gesture.moveTo(Offset.lerp(start, end, i / 6)!);
    await tester.pump(const Duration(milliseconds: 30));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press reorders rooms and Bot siblings in one layout draft', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    final team = sampleTeam(working: false)
      ..['prefs'] = {
        'goLayout': {
          'revision': 0,
          'folders': [
            {'id': 'release', 'name': 'Release folder', 'parentId': null},
          ],
          'bots': [
            {'botId': 'b2', 'folderId': 'release'},
            {'botId': 'm1', 'folderId': null},
            {'botId': 'b3', 'folderId': 'release'},
          ],
          'rooms': [
            for (final id in ['r1', 'r2', 'r3']) {'roomId': id, 'folderId': null},
          ],
        },
      };
    team['rooms'] = [
      ...team['rooms'] as List,
      {
        'id': 'r2',
        'name': 'Second room',
        'members': ['m1', 'b2'],
      },
      {
        'id': 'r3',
        'name': 'Third room',
        'members': ['m1', 'b3'],
      },
    ];
    final fake = FakeDsBotTransport(team: team);
    fake.handlers['set-prefs'] = (payload) {
      team['revision'] = 8;
      return team['prefs'] = {
        'goLayout': {...payload['goLayout'] as Map<String, Object?>, 'revision': 1},
      };
    };
    await tester.pumpWidget(
      goldenApp(home: const BotsPage(), brightness: Brightness.light, overrides: dsBotOverrides(fake)),
    );
    await tester.pumpAndSettle();

    Future<void> tap(Finder finder) async {
      await tester.scrollUntilVisible(finder, 180);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final edit = find.text('编辑组织');
    final save = find.widgetWithText(FilledButton, '保存');
    await tap(edit);
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(_handle('Chief'), findsNothing);
    expect(_handle('Release folder'), findsNothing);

    // Bring the room group back into view before dragging across two siblings.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    await _drag(tester, '发布会', 'Third room');
    expect(tester.getCenter(find.text('Third room')).dy, lessThan(tester.getCenter(find.text('发布会')).dy));
    await _drag(tester, 'Coder', 'Writer');
    expect(tester.getCenter(find.text('Coder')).dy, lessThan(tester.getCenter(find.text('Writer')).dy));
    expect(fake.endpoints, isNot(contains('set-prefs')));

    await tap(save);
    final write = fake.calls.singleWhere((call) => call.$1 == 'set-prefs');
    final saved = DsBotGoLayout.parse(write.$2['goLayout'])!;
    expect(saved.revision, 0);
    expect(saved.rooms, ['r2', 'r3', 'r1']);
    expect(saved.bots, [
      (botId: 'b3', folderId: 'release'),
      (botId: 'm1', folderId: null),
      (botId: 'b2', folderId: 'release'),
    ]);
    await tap(edit);
    expect(tester.getCenter(find.text('Third room')).dy, lessThan(tester.getCenter(find.text('发布会')).dy));
    expect(tester.getCenter(find.text('Coder')).dy, lessThan(tester.getCenter(find.text('Writer')).dy));
  });
}
