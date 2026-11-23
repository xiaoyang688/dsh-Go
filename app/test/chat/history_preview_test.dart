import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/history_preview.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_sync_host.dart';
import 'support/harness.dart';

UserChatItem user(String text, {String source = 'user'}) =>
    UserChatItem(seq: 0, time: DateTime.utc(2026), text: text, images: const [], files: const [], sourceKind: source);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('stores bounded recent durable conversation text only', () {
    final cache = HistoryPreviewCache();
    final items = [
      for (var i = 0; i < 10; i++) user('$i'),
      const AssistantChatItem(id: 'a1', seq: 1, text: 'reply', reasoning: 'private'),
      user('😀' * 300),
      user('hidden', source: 'working-directory'),
      const AssistantChatItem(id: 'draft', text: 'draft', reasoning: '', streaming: true),
    ];
    cache.remember('S', items);
    expect(cache.read('S'), [
      for (var i = 6; i < 10; i++) (user: true, text: '$i'),
      (user: false, text: 'reply'),
      (user: true, text: '😀' * 256),
    ]);
    for (var i = 0; i < HistoryPreviewCache.sessions; i++) {
      cache.remember('$i', items);
    }
    expect(cache.read('S'), isEmpty);
    cache.remember('0', []);
    expect(cache.read('0'), isEmpty);
  });

  test('replacement host, credentials, workspace and unknown scope discard entries', () async {
    final c = ProviderContainer(
      overrides: [historyPreviewScopeProvider.overrideWithValue((const ReadListIdentity('host A/auth A'), 'w1'))],
    );
    addTearDown(c.dispose);
    for (final scope in <HistoryPreviewScope?>[
      (const ReadListIdentity('host B/auth A'), 'w1'),
      (const ReadListIdentity('host B/auth B'), 'w1'),
      (const ReadListIdentity('host B/auth B'), 'w2'),
      null,
    ]) {
      c.read(historyPreviewCacheProvider)!.remember('same session', [user('old')]);
      c.updateOverrides([historyPreviewScopeProvider.overrideWithValue(scope)]);
      expect(c.read(historyPreviewCacheProvider)?.read('same session') ?? [], isEmpty);
    }
  });

  testWidgets('normal chat shows a read-only preview until its live rows arrive', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    final ui = ChatHarness(
      session: 'S',
      states: const {
        'S': ChatState(syncing: true, preview: [(user: true, text: 'cached words')]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: ui.overrides));
    await pumpFrames(tester);
    expect(find.text('cached words'), findsOneWidget);
    expect(find.text('最近消息 · 只读预览'), findsOneWidget);
    expect(tester.widget<Composer>(find.byType(Composer)).sessionReady, isFalse);
    ui.controllers['S']!.emit(ChatState(loading: false, items: [user('fresh words')]));
    await pumpFrames(tester);
    expect(find.text('cached words'), findsNothing);
    expect(find.text('fresh words'), findsOneWidget);
  });

  test('reopen presents cached text, follows again and replaces it with current snapshot', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start(
        initialSnapshot: false,
        overrides: [historyPreviewScopeProvider.overrideWithValue((const ReadListIdentity('host/auth'), 'workspace'))],
      );
      try {
        final snapshot = syncSnapshot(1)
          ..['records'] = [
            {
              'type': 'event',
              'event': {'type': 'user/message', 'seq': 0, 'time': 1792700000000, 'data': syncItem('old words')},
            },
          ];
        h.follows.single.socket.item(h.follows.single.id, snapshot);
        await waitSync(() => h.state.controlReady, 'first snapshot');
        expect(h.state.items.whereType<UserChatItem>().single.text, 'old words');
        final cache = h.container.read(historyPreviewCacheProvider)!;
        expect(cache.read('S'), [(user: true, text: 'old words')]);
        // A fresh controller shares only the process-scoped display cache.
        final reopened = await SyncHarness.start(
          initialSnapshot: false,
          overrides: [historyPreviewCacheProvider.overrideWithValue(cache)],
        );
        try {
          expect(reopened.state.preview, [(user: true, text: 'old words')]);
          expect(reopened.state.items, isEmpty);
          expect(reopened.state.pending, isEmpty);
          expect(reopened.state.controlReady, isFalse);
          expect(await reopened.chat.send('interrupt', mode: SendMode.interrupt), isFalse);
          expect(reopened.methods, isNot(contains('session/prompt')));
          final follow = reopened.follows.single;
          follow.socket.item(follow.id, syncSnapshot(2));
          await waitSync(() => reopened.state.controlReady, 'replacement snapshot');
          expect(reopened.state.preview, isEmpty);
          expect(reopened.state.pending.single.text, 'queue-run-2');
          expect(cache.read('S'), isEmpty);
        } finally {
          await reopened.close();
        }
      } finally {
        await h.close();
      }
    }, RealSyncHttp());
  });
}
