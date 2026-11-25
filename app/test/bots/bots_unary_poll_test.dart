import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show fakeConnection;
import 'support.dart';

void main() {
  testWidgets('the unary Bot route polls reads only and pauses in the background', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeDsBotTransport();
    final api = DsBotApi(
      DsBotUnaryTransport(
        (endpoint, payload, timeout) async => {
          'status': 200,
          'json': {'ok': true, 'value': await fake.call(endpoint, payload, timeout: timeout)},
        },
      ),
    );
    final scope = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
        dsBotApiFactoryProvider.overrideWithValue((_) => api),
      ],
    );
    try {
      scope.listen(dsBotProvider, (_, _) {});
      await tester.pump();
      expect(scope.read(dsBotProvider).ready, isTrue);
      expect(scope.read(dsBotProvider).feedConnected, isFalse);
      final bot = botChatProvider('m1');
      scope.listen(bot, (_, _) {});
      scope.read(dsBotViewingProvider.notifier).set('m1');
      await tester.pump();
      expect(scope.read(bot).items, isNotEmpty);
      fake.chatItems = [
        ...fake.chatItems,
        {'id': 'new', 'kind': 'bot', 'text': 'Polled reply'},
      ];
      await tester.pump(DsBotController.unaryPollEvery);
      expect(scope.read(bot).items.last.text, 'Polled reply');
      expect(fake.endpoints, containsAllInOrder(['hello', 'state', 'chat', 'notices', 'state', 'chat']));
      expect(fake.endpoints.toSet(), {'hello', 'state', 'chat', 'notices'});

      scope.read(appForegroundProvider.notifier).set(false);
      final count = fake.calls.length;
      await tester.pump(DsBotController.unaryPollEvery * 2);
      expect(fake.calls, hasLength(count));
      final delayedNotices = Completer<Object?>();
      fake.handlers['notices'] = (_) => delayedNotices.future;
      fake.chatItems = [
        ...fake.chatItems,
        {'id': 'resumed', 'kind': 'bot', 'text': 'Reply after resume'},
      ];
      scope.read(appForegroundProvider.notifier).set(true);
      await tester.pump();
      expect(scope.read(bot).items.last.text, 'Reply after resume');
      expect(fake.endpoints.skip(count), unorderedEquals(['notices', 'chat']));
      delayedNotices.complete({'boot': 'boot-1', 'seq': 0, 'reset': false, 'notices': <Object?>[]});
      await tester.pump();
      expect(fake.endpoints.skip(count), contains('state'));
    } finally {
      scope.dispose();
      await tester.pump();
    }
  });
}
