import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

const _layout = {
  'revision': 0,
  'folders': [
    {'id': 'release', 'name': 'Release folder', 'parentId': null},
    {'id': 'draft', 'name': 'Draft folder', 'parentId': null},
  ],
  'bots': [
    {'botId': 'm1', 'folderId': 'release'},
    {'botId': 'b3', 'folderId': 'release'},
  ],
  'rooms': [],
};

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(WidgetTester tester, FakeDsBotTransport fake) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(home: const BotsPage(), brightness: Brightness.light, overrides: dsBotOverrides(fake)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder row(String title) => find.widgetWithText(ListPageRow, title);
  Future<void> action(WidgetTester tester, String title, String label) async {
    await tap(tester, find.descendant(of: row(title), matching: find.byTooltip('组织操作')));
    await tap(tester, find.text(label));
  }

  testWidgets('folders expand and one host write saves the hierarchy and room order', (tester) async {
    final team = sampleTeam();
    team['rooms'] = [
      ...team['rooms'] as List,
      {
        'id': 'r2',
        'name': 'Older room',
        'members': ['m1', 'b2'],
      },
    ];
    team['prefs'] = {'goLayout': _layout};
    final fake = FakeDsBotTransport(team: team);
    fake.handlers['set-prefs'] = (payload) {
      final updated = {...payload['goLayout'] as Map<String, Object?>, 'revision': 1};
      team['revision'] = 8;
      return team['prefs'] = {'goLayout': updated};
    };
    await open(tester, fake);
    expect(find.text('Coder'), findsNothing);
    expect(find.text('Writer'), findsNothing);
    expect(find.text('未分组'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Chief')).dy, lessThan(tester.getTopLeft(find.text('Release folder')).dy));
    await tap(tester, find.text('未分组'));
    expect(find.text('Writer'), findsOneWidget);
    await tap(tester, find.text('未分组'));
    await tap(tester, find.text('Release folder'));
    expect(find.text('Coder'), findsOneWidget);
    await tap(tester, find.text('Release folder'));
    expect(find.text('Coder'), findsNothing);

    await tap(tester, find.text('编辑组织'));
    await action(tester, 'Older room', '上移');
    await action(tester, 'Draft folder', '移动到文件夹');
    await tap(tester, find.text('Release folder').last);
    await action(tester, 'Writer', '移动到文件夹');
    await tap(tester, find.text('Release folder / Draft folder'));
    await action(tester, 'Coder', '移动到文件夹');
    await tap(tester, find.text('Release folder / Draft folder'));
    await action(tester, 'Coder', '上移');
    await tap(tester, find.text('保存'));

    final request = fake.calls.singleWhere((call) => call.$1 == 'set-prefs');
    expect(request.$2.keys, ['goLayout']);
    final saved = DsBotGoLayout.parse(request.$2['goLayout'])!;
    expect(saved.revision, 0);
    expect(saved.rooms, ['r2', 'r1']);
    expect(saved.folders.last.parentId, 'release');
    expect(saved.bots.where((bot) => bot.folderId == 'draft').map((bot) => bot.botId), ['b3', 'b2']);

    await tap(tester, find.text('编辑组织'));
    // AppPage loads its single editor column, so these coordinates share the
    // same scroll transform even when a row is outside the viewport.
    expect(tester.getTopLeft(find.text('Older room')).dy, lessThan(tester.getTopLeft(find.text('发布会')).dy));
    expect(
      tester.getTopLeft(find.text('Draft folder')).dx,
      greaterThan(tester.getTopLeft(find.text('Release folder')).dx),
    );
    expect(tester.getTopLeft(find.text('Coder')).dy, lessThan(tester.getTopLeft(find.text('Writer')).dy));
  });

  testWidgets('losing the authenticated feed disables an open draft before it can write', (tester) async {
    final fake = FakeDsBotTransport(
      team: {
        ...sampleTeam(),
        'prefs': {'goLayout': _layout},
      },
    );
    await open(tester, fake);
    await tap(tester, find.text('编辑组织'));
    await action(tester, 'Draft folder', '上移');
    final save = find.widgetWithText(FilledButton, '保存');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    fake.dropFeed().ignore();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(fake.endpoints, isNot(contains('set-prefs')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });

  testWidgets('older hosts omit editing and read-only hosts disable it', (tester) async {
    final legacy = FakeDsBotTransport();
    await open(tester, legacy);
    expect(find.text('编辑组织'), findsNothing);
    expect(legacy.endpoints, isNot(contains('set-prefs')));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    final readOnly = FakeDsBotTransport(
      team: {
        ...sampleTeam(),
        'prefs': {'goLayout': _layout},
        'readOnly': 'Locked',
      },
    );
    await open(tester, readOnly);
    expect(find.text('Release folder'), findsOneWidget);
    expect(tester.widget<ListPageRow>(row('编辑组织')).onTap, isNull);
    expect(readOnly.endpoints, isNot(contains('set-prefs')));
  });
}
