import 'dart:convert';

import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

final _imageData = tinyPhoto.split(',').last;

class _WorkspaceReader implements WorkspaceImageReader {
  final reads = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add((sessionId, path));
    return RasterImage(MemoryImage(base64Decode(_imageData)));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (isRoom, page) in [(false, const BotChatPage(botId: 'b2')), (true, const RoomChatPage(roomId: 'r1'))]) {
    testWidgets('${isRoom ? 'group' : 'direct'} history shows attachments and scopes reply images', (tester) async {
      final fake = FakeDsBotTransport();
      final hello = fake.helloAnswer();
      fake.handlers['hello'] = (_) => {
        ...hello,
        'capabilities': [...hello['capabilities']! as List, 'images', 'image-preview'],
      };
      var fail = true;
      fake.handlers['image'] = (payload) {
        if (payload['attachmentId'] == 'retry' && fail) {
          throw const DshRemoteException('bot/not-found', 'fixture missing image');
        }
        return {'mime': 'image/png', 'data': _imageData};
      };
      final items = [
        {'id': 'legacy', 'kind': 'user', 'images': 1},
        {
          'id': 'photo',
          'kind': 'user',
          'images': 1,
          'imageRefs': [
            {'attachmentId': 'retry', 'name': 'upload.png'},
          ],
        },
        {
          'id': 'reply',
          'kind': 'bot',
          'botId': 'b2',
          'sessionId': 'older-part',
          'text': '![Result](/workspaces/default/result.png)',
          'imageRefs': [
            {'attachmentId': 'reply-ref', 'name': 'reply.png'},
          ],
        },
      ];
      if (isRoom) {
        fake.roomItems = items;
      } else {
        fake.chatItems = items;
      }
      final workspace = _WorkspaceReader();
      usePhoneView(tester);
      await tester.pumpWidget(
        goldenApp(
          home: page,
          brightness: Brightness.light,
          overrides: [
            ...dsBotOverrides(fake),
            workspaceImageReaderProvider.overrideWithValue(CachedImageReader(workspace)),
          ],
        ),
      );
      Future<void> frames() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await frames();
      expect(find.text('［图片］'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Image && w.semanticLabel == 'reply.png'), findsOneWidget);
      expect(workspace.reads, [('older-part', '/workspaces/default/result.png')]);
      final failed = find.byTooltip('图片下载失败，请重试');
      expect(failed, findsOneWidget);
      fail = false;
      await tester.tap(failed);
      await frames();
      expect(find.byWidgetPredicate((w) => w is Image && w.semanticLabel == 'upload.png'), findsOneWidget);
      expect(
        fake.calls.where((c) => c.$1 == 'image').map((c) => c.$2),
        unorderedEquals([
          {'sessionId': isRoom ? 'r1' : 'b2', 'attachmentId': 'retry', 'preview': true},
          {'sessionId': 'older-part', 'attachmentId': 'reply-ref', 'preview': true},
          {'sessionId': isRoom ? 'r1' : 'b2', 'attachmentId': 'retry', 'preview': true},
        ]),
      );
    });
  }
}
