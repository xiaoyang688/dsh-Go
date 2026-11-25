// A failed send may restore the editor only while it still belongs to the
// same connection and conversation. Drafts are not moved between targets.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart';
import '../../state/bots_state.dart';

Future<bool> sendBotDraft(
  BuildContext context,
  WidgetRef ref,
  TextEditingController input, {
  String? botId,
  String? roomId,
  required List<DraftAttachment> images,
  required Future<bool> Function(String text, List<String> images) send,
}) async {
  final text = input.text.trim();
  if (text.isEmpty && images.isEmpty) return false;
  final hub = ref.read(dsBotProvider.notifier);
  final api = hub.api;
  final origin = ref.read(dsBotProvider);
  if (api == null) return false;
  final part = botId == null ? null : origin.team?.bot(botId)?.sessionId;
  bool sameTarget(DsBotStatus status) =>
      ref.read(dsBotProvider.notifier).api == api &&
      status.host == origin.host &&
      status.hello?.boot == origin.hello?.boot &&
      status.readOnly == null &&
      status.ready &&
      (botId == null || (status.team?.bot(botId) != null && status.team?.bot(botId)?.sessionId == part)) &&
      (roomId == null || status.team?.room(roomId) != null);
  var retired = false;
  // Retirement is permanent even if the same part or entity reappears before
  // the pending request completes, including changes between rendered frames.
  final subscription = ref.listenManual<DsBotStatus>(dsBotProvider, (_, status) {
    if (!sameTarget(status)) retired = true;
  });
  bool current() => context.mounted && !retired && sameTarget(ref.read(dsBotProvider));
  try {
    final ids = <String>[];
    try {
      for (final image in images) {
        if (!current()) return false;
        ids.add(await api.stageImage(image.mediaType!, image.bytes));
      }
    } catch (_) {
      if (context.mounted && current()) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(context.l10n.stateAttachmentUploadFailed)));
      }
      return false;
    }
    if (!current()) return false;
    // Typing while photos are staged creates the next draft.
    final cleared = input.text.trim() == text;
    if (cleared) input.clear();
    final ok = await send(text, ids);
    if (!ok && cleared && current() && input.text.isEmpty) input.text = text;
    return ok;
  } finally {
    subscription.close();
  }
}
