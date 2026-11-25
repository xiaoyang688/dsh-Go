import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../chat/render/markdown_image.dart' show inlineImageProvider;
import '../chat/widgets/attachments.dart' show openImageViewer;
import '../theme/app_icons.dart';

final _imageProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String)>((ref, key) async {
  final hub = ref.watch(dsBotProvider.notifier);
  final (_, _, api, canRead, preview) = ref.watch(
    dsBotProvider.select(
      (s) => (s.host, s.hello?.boot, hub.api, s.ready && s.supports('images'), s.supports('image-preview')),
    ),
  );
  if (api == null || !canRead) return null;
  return api.image(key.$1, key.$2, preview: preview);
}, retry: (_, _) => null);

/// Attachment previews read through the Bot API of the active Host.
class BotHistoryImages extends StatelessWidget {
  const BotHistoryImages({super.key, required this.item, required this.conversationId, this.alignEnd = false});

  final DsBotItem item;
  final String conversationId;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
    spacing: 6,
    runSpacing: 6,
    children: [for (final image in item.imageRefs) _Preview(sessionId: item.sessionId ?? conversationId, image: image)],
  );
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.sessionId, required this.image});

  final String sessionId;
  final DsBotImageRef image;
  static const _size = Size(120, 96);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = _imageProvider((sessionId, image.attachmentId));
    final value = ref.watch(provider);
    final l10n = context.l10n;
    final label = image.name ?? l10n.chatImage;
    Widget unavailable() => IconButton(
      onPressed: () => ref.invalidate(provider),
      tooltip: l10n.chatImageDownloadFailed,
      icon: const Icon(AppIcons.image),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox.fromSize(
          size: _size,
          child: value.when(
            skipLoadingOnRefresh: false,
            loading: () => Center(child: Text(l10n.mediaImageLoading)),
            error: (_, _) => Center(child: unavailable()),
            data: (bytes) {
              if (bytes == null) return Center(child: Text(l10n.botsImagePlaceholder));
              final source = MemoryImage(bytes);
              return GestureDetector(
                onTap: () => openImageViewer(context, source, heroTag: Object(), name: label),
                child: Image(
                  image: inlineImageProvider(source, MediaQuery.devicePixelRatioOf(context), _size),
                  fit: BoxFit.contain,
                  semanticLabel: label,
                  errorBuilder: (_, _, _) => Center(child: unavailable()),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
