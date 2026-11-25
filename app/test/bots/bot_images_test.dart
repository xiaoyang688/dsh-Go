import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_composer.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Picker extends DeviceAttachmentPicker {
  const _Picker(this.bytes);
  final Uint8List bytes;

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) async => [DraftAttachment.sniff('photo.png', bytes)];
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a large photo fits the relay payload as JPEG', () {
    final pixels = img.Image(width: 1050, height: 700);
    final random = Random(8);
    for (final pixel in pixels) {
      pixel.setRgb(random.nextInt(256), random.nextInt(256), random.nextInt(256));
    }
    final original = img.encodePng(pixels);
    expect(original.length, greaterThan(maxBotImageBytes));
    final resized = fitBotImage(original)!;
    expect(resized.length, lessThanOrEqualTo(maxBotImageBytes));
    expect(img.decodeJpg(resized), isNotNull);
  });

  for (final (target, page) in [('b2', const BotChatPage(botId: 'b2')), ('r1', const RoomChatPage(roomId: 'r1'))]) {
    testWidgets('$target stages only on send, keeps draft on failure, and sends an image-only message', (tester) async {
      final bytes = img.encodePng(img.Image(width: 2, height: 2));
      final failedStage = Completer<Object?>();
      var count = 0;
      final fake = FakeDsBotTransport();
      final hello = fake.helloAnswer();
      fake.handlers['hello'] = (_) => {
        ...hello,
        'capabilities': [...hello['capabilities']! as List, 'send-images'],
      };
      fake.handlers['stage-image'] = (_) => ++count == 1 ? failedStage.future : {'id': 'staged-2'};
      usePhoneView(tester);
      await tester.pumpWidget(
        goldenApp(
          home: page,
          brightness: Brightness.light,
          overrides: [...dsBotOverrides(fake), attachmentPickerProvider.overrideWithValue(_Picker(bytes))],
        ),
      );
      Future<void> frames() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await frames();
      await tester.tap(find.byType(AttachButton));
      await frames();
      await tester.tap(find.text('相册'));
      await frames();
      expect(find.byType(ComposerTray), findsOneWidget);
      expect(fake.endpoints, isNot(contains('stage-image')));
      await tester.tap(find.byIcon(AppIcons.send));
      await tester.pump();
      expect(count, 1);
      expect(fake.endpoints, isNot(contains('send')));
      failedStage.completeError(const DshRemoteException('bot/invalid', 'fixture error'));
      await frames();
      expect(find.byType(ComposerTray), findsOneWidget);
      expect(fake.endpoints, isNot(contains('send')));
      await tester.pump(const Duration(seconds: 5));
      await frames();
      await tester.tap(find.byIcon(AppIcons.send));
      await frames();
      expect(find.byType(ComposerTray), findsNothing);
      expect(fake.calls.where((c) => c.$1 == 'stage-image').map((c) => c.$2), [
        {'mediaType': 'image/png', 'data': base64Encode(bytes)},
        {'mediaType': 'image/png', 'data': base64Encode(bytes)},
      ]);
      expect(fake.calls.singleWhere((c) => c.$1 == 'send').$2, {
        'sessionId': target,
        'text': '',
        'images': ['staged-2'],
      });
    });
  }
}
