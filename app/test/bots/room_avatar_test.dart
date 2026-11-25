import 'package:dsh_app/ui/bots/bot_avatar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final team = DsBotTeam.fromJson({
    'bots': [
      for (var i = 1; i <= 6; i++) {'id': 'b$i', 'name': 'Bot $i'},
    ],
  });

  for (final size in [32.0, 40.0, 56.0, 64.0]) {
    for (final count in [1, 2, 3, 4, 6]) {
      testWidgets('$count members fit the $size group portrait', (tester) async {
        final room = DsBotRoom(
          id: 'room',
          name: 'Room',
          members: [for (var i = 1; i <= count; i++) 'b$i'],
          admin: 'b$count',
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Center(
                child: RoomAvatar(room: room, team: team, size: size),
              ),
            ),
          ),
        );
        final tile = tester.getRect(find.byType(RoomAvatar));
        final faces = find.byType(BotAvatar);
        final shown = count > 4 ? 3 : count;
        expect(tester.widgetList<BotAvatar>(faces).map((face) => face.bot.id), [
          for (var i = 1; i <= shown; i++) 'b$i',
        ]);
        for (var i = 0; i < shown; i++) {
          final face = tester.getRect(faces.at(i));
          expect(
            face.width,
            closeTo(
              size *
                  (count < 3
                      ? 2 / 3
                      : count == 3
                      ? 5 / 9
                      : .5),
              .001,
            ),
          );
          expect(face.left, greaterThanOrEqualTo(tile.left));
          expect(face.right, lessThanOrEqualTo(tile.right + .001));
          expect(face.top, greaterThanOrEqualTo(tile.top));
          expect(face.bottom, lessThanOrEqualTo(tile.bottom + .001));
        }
        expect(find.text('+3'), count == 6 ? findsOneWidget : findsNothing);
      });
    }
  }

  testWidgets('unknown and duplicate IDs do not consume portrait seats', (tester) async {
    const room = DsBotRoom(id: 'room', name: 'Room', members: ['unknown', 'b1', 'b1', 'b2']);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Center(
            child: RoomAvatar(room: room, team: team),
          ),
        ),
      ),
    );
    expect(find.byType(BotAvatar), findsNWidgets(2));
    expect(find.textContaining('+'), findsNothing);
  });
}
