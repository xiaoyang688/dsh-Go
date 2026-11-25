import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show fakeConnection, usePhoneView;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

final _connected = NotifierProvider<_Connected, bool>(_Connected.new);
final _identity = NotifierProvider<_Identity, ReadListIdentity?>(_Identity.new);

class _Connected extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool connected) => state = connected;
}

class _Identity extends Notifier<ReadListIdentity?> {
  @override
  ReadListIdentity? build() => const ReadListIdentity('original');
  void change() => state = const ReadListIdentity('different');
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  @override
  void select(HostRef host) => state = host;
}

Map<String, Object?> _page(List<Object?> items, {Object? cursor}) => {
  'sessionId': 'b2-c',
  'roomId': 'r1',
  'items': items,
  'cursor': cursor,
  'running': true,
  'speaking': 'b2',
};

const _shown = [
  {
    'kind': 'bot',
    'id': '1',
    'text': 'visible history',
    'imageRefs': [
      {'attachmentId': 'old-image'},
    ],
    'whole': {'length': 100, 'file': {}},
  },
  {'kind': 'bot', 'id': '2', 'text': 'unfinished row', 'live': true},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final room in [false, true]) {
    final id = room ? 'r1' : 'b2';
    final endpoint = room ? 'room-chat' : 'chat';
    final botProvider = botChatProvider(id);
    final roomProvider = roomChatProvider(id);

    testWidgets('$endpoint shows last history on resume and restores the existing text draft', (tester) async {
      usePhoneView(tester);
      final fake = FakeDsBotTransport()..helloOnFeed = false;
      fake.handlers[endpoint] = (_) => _page(_shown);
      await tester.pumpWidget(
        goldenApp(
          home: room ? const RoomChatPage(roomId: 'r1') : const BotChatPage(botId: 'b2'),
          brightness: Brightness.light,
          overrides: [
            ...dsBotOverrides(fake),
            readListIdentityProvider.overrideWithValue(const ReadListIdentity('verified')),
          ],
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('visible history', findRichText: true), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'keep my unsent draft');
      final container = ProviderScope.containerOf(tester.element(find.byType(TextField)));
      final reply = Completer<Object?>();
      fake.handlers[endpoint] = (_) => reply.future;
      final foreground = container.read(appForegroundProvider.notifier);
      foreground.set(false);
      foreground.set(true);
      await tester.pump();
      expect(find.byType(BotReconnectTranscript), findsOneWidget);
      expect(find.textContaining('visible history', findRichText: true), findsOneWidget);
      expect(find.textContaining('unfinished row', findRichText: true), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(DshUiCard), findsNothing);
      expect(find.byIcon(AppIcons.send), findsNothing);
      expect(fake.endpoints, isNot(contains('send')));

      reply.complete(
        _page([
          {'kind': 'bot', 'text': 'fresh history'},
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BotReconnectTranscript), findsNothing);
      expect(find.textContaining('fresh history', findRichText: true), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'keep my unsent draft');
    });

    for (final outcome in ['empty', 'auth refusal', 'identity', 'host', 'boot', 'leave', 'removed']) {
      test('$endpoint holds only visible history during reconnect, then handles $outcome', () async {
        final fake = FakeDsBotTransport()..helloOnFeed = false;
        fake.handlers[endpoint] = (_) => _page(_shown, cursor: 'prior-cursor');
        final container = ProviderContainer(
          overrides: [
            activeHostProvider.overrideWith(_Host.new),
            activeConnectionProvider.overrideWith((ref) {
              final host = ref.watch(activeHostProvider);
              return AsyncData(ref.watch(_connected) && host.isLocal ? fakeConnection : null);
            }),
            readListIdentityProvider.overrideWith((ref) => ref.watch(_identity)),
            dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(fake)),
          ],
        );
        addTearDown(container.dispose);
        if (room) {
          container.listen(roomProvider, (_, _) {});
        } else {
          container.listen(botProvider, (_, _) {});
        }
        List<DsBotItem> items() => room ? container.read(roomProvider).items : container.read(botProvider).items;
        bool stale() => room ? container.read(roomProvider).stale : container.read(botProvider).stale;
        Object? cursor() => room ? container.read(roomProvider).cursor : container.read(botProvider).cursor;
        Future<bool> send() => room
            ? container.read(roomProvider.notifier).send('stale-send')
            : container.read(botProvider.notifier).send('stale-send');
        Future<void> earlier() => room
            ? container.read(roomProvider.notifier).loadEarlier()
            : container.read(botProvider.notifier).loadEarlier();

        container.read(dsBotViewingProvider.notifier).set(id);
        await settle(12);
        expect(items().map((i) => i.text), ['visible history', 'unfinished row']);
        expect(items().first.imageRefs, isNotEmpty);
        expect(await send(), isTrue);

        final late = Completer<Object?>();
        fake.handlers[endpoint] = (_) => late.future;
        final oldPagination = earlier();
        container.read(_connected.notifier).set(false);
        await settle(12);
        expect(stale(), isTrue);
        expect(items().map((i) => i.text), ['visible history']);
        expect(items().single.imageRefs, isEmpty);
        expect(items().single.whole, isNull);
        expect(cursor(), isNull);
        if (room) {
          expect(container.read(roomProvider).pending, isEmpty);
          expect(container.read(roomProvider).speaking, isNull);
          expect(container.read(roomProvider).running, isFalse);
        } else {
          expect(container.read(botProvider).pending, isEmpty);
          expect(container.read(botProvider).sessionId, isNull);
        }
        final calls = fake.calls.length;
        expect(await send(), isFalse);
        await earlier();
        expect(fake.calls, hasLength(calls));

        final fresh = Completer<Object?>();
        fake.handlers[endpoint] = (_) => fresh.future;
        switch (outcome) {
          case 'identity':
            container.read(_identity.notifier).change();
          case 'host':
            container.read(activeHostProvider.notifier).select(const HostRef.ssh('another'));
          case 'leave':
            container.read(dsBotViewingProvider.notifier).leave(id);
          case 'boot':
            fake.handlers['hello'] = (_) => {...fake.helloAnswer(), 'boot': 'new-boot'};
          case 'removed':
            fake.handlers['state'] = (_) => {...sampleTeam(), (room ? 'rooms' : 'bots'): <Object?>[]};
        }
        container.read(_connected.notifier).set(true);
        await settle(12);
        if (outcome == 'auth refusal' || outcome == 'empty') {
          expect(stale(), isTrue);
          expect(await send(), isFalse);
          if (outcome == 'auth refusal') {
            fresh.completeError(const DshHttpException(401, 'synthetic'));
          } else {
            fresh.complete(_page([]));
          }
        } else {
          expect(stale(), isFalse);
          expect(items(), isEmpty);
          fresh.complete(_page([]));
        }
        late.complete(_page(_shown));
        await oldPagination;
        await settle(12);
        expect(stale(), isFalse);
        expect(items(), isEmpty);
        if (outcome == 'auth refusal') expect(container.read(dsBotProvider).ready, isFalse);
      });
    }
  }
}
