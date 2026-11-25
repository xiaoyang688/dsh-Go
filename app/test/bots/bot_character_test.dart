import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/bots/bot_avatar.dart';
import 'package:dsh_app/ui/bots/bot_character.dart';
import 'package:dsh_app/ui/bots/bot_character_data.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart' show tinyPhoto;

void main() {
  test('host shapes take precedence and unsupported shapes use deterministic marks', () {
    expect(botCharacterId(const DsBot(id: 'me', name: 'Main', shape: 'whale')), 'whale');
    expect(botCharacterId(const DsBot(id: '', name: '', shape: 'unknown')), 'gumdrop');
    expect(botCharacterId(const DsBot(id: 'b2', name: '', shape: 'unknown')), 'acorn');
  });

  test('live status distinguishes work, room speech, and an approval', () {
    const live = DsBotLive(
      bots: {'bot': DsBotWork(), 'other': DsBotWork()},
      activity: {'bot': 'searching', 'other': 'thinking', 'wait': 'waiting'},
      rooms: {
        'room': [DsBotWork(botId: 'bot', speaking: true)],
      },
      approvals: [DsBotApproval(id: 'p', sessionId: 's', botId: 'other')],
    );
    expect(botAvatarState(live, 'bot'), BotAvatarState.searching);
    expect(botAvatarState(live, 'bot', roomId: 'room'), BotAvatarState.sending);
    expect(botAvatarState(live, 'bot', roomId: 'different-room'), BotAvatarState.idle);
    expect(botAvatarState(live, 'other'), BotAvatarState.alert);
    expect(botAvatarState(live, 'wait'), BotAvatarState.waiting);
  });

  testWidgets('all installed characters paint as vectors', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Wrap(
            children: [
              for (final shape in dsBotCharacters.keys)
                BotAvatar(
                  bot: DsBot(id: shape, name: shape, shape: shape),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(BotCharacter), findsNWidgets(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a host photo outranks the fallback vector', (tester) async {
    const key = (botId: 'photo', ref: 'host-ref');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dsBotPhotoProvider(key).overrideWith((ref) async => decodeDataUrl(tinyPhoto))],
        child: const MaterialApp(
          home: Center(
            child: BotAvatar(
              bot: DsBot(id: 'photo', name: 'Photo', imageRef: 'host-ref', shape: 'whale'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ClipOval), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ImageProvider>());
    await tester.runAsync(() => precacheImage(provider, tester.element(find.byType(Image))));
    await tester.pump();
    expect(find.byType(BotCharacter), findsNothing);
  });

  testWidgets('idle blinks are brief and reduced motion switches off active animation', (tester) async {
    Widget tree({required bool reduced, required BotAvatarState state}) => ProviderScope(
      child: MaterialApp(
        theme: buildLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Center(
            child: BotAvatar(
              bot: const DsBot(id: 'bot', name: 'Bot'),
              live: true,
              state: state,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(tree(reduced: false, state: BotAvatarState.idle));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(Duration(milliseconds: 1900 + dsBotFnv1a('bot') % 1900));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(tree(reduced: false, state: BotAvatarState.thinking));
    await tester.pump(const Duration(milliseconds: 300));
    final avatar = find.byType(BotCharacter);
    final activeCenter = tester.getCenter(avatar);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getCenter(avatar), isNot(activeCenter));
    await tester.pumpWidget(tree(reduced: true, state: BotAvatarState.alert));
    final stillCenter = tester.getCenter(avatar);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.getCenter(avatar), stillCenter);
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('?'), findsOneWidget);
  });
}
