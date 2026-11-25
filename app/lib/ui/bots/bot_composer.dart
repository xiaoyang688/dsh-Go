import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../l10n/l10n.dart';
import '../../state/attachments.dart';
import '../../state/settings_state.dart';
import '../chat/composer.dart';
import '../chat/widgets/attachments.dart';
import '../theme/app_icons.dart';

// The relayed 1 MiB frame wraps both the image and the encrypted RPC in
// base64. 512 KiB leaves room for both encodings and the two envelopes.
const maxBotImageBytes = 512 * 1024;

Uint8List? fitBotImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final photo = img.bakeOrientation(decoded);
  for (final (side, quality) in [(1600, 78), (1000, 72), (640, 65)]) {
    final resized = photo.width <= side && photo.height <= side
        ? photo
        : img.copyResize(
            photo,
            width: photo.width >= photo.height ? side : null,
            height: photo.height > photo.width ? side : null,
            interpolation: img.Interpolation.average,
          );
    final encoded = img.encodeJpg(resized, quality: quality);
    if (encoded.length <= maxBotImageBytes) return encoded;
  }
  return null;
}

/// The photo draft belongs to one host, boot and conversation, set by the key.
class BotComposer extends ConsumerStatefulWidget {
  const BotComposer({
    required super.key,
    required this.controller,
    required this.focusNode,
    required this.connected,
    required this.running,
    required this.sendImages,
    required this.current,
    required this.onSend,
    required this.onStop,
    required this.placeholder,
    this.mention,
    this.onPickSkill,
    this.onKeyEvent,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool connected;
  final bool running;
  final bool sendImages;
  final bool Function() current;
  final Future<bool> Function(List<DraftAttachment> images) onSend;
  final VoidCallback onStop;
  final String placeholder;
  final Widget? mention;
  final VoidCallback? onPickSkill;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  ConsumerState<BotComposer> createState() => _BotComposerState();
}

class _BotComposerState extends ConsumerState<BotComposer> {
  final _images = <DraftAttachment>[];
  bool _busy = false;

  void _showProblem(String message) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _pick() async {
    if (_busy || !widget.sendImages || !widget.current()) return;
    final current = widget.current;
    final room = maxAttachments - _images.length;
    final l10n = context.l10n;
    if (room == 0) {
      _showProblem(l10n.chatAttachmentLimit(maxAttachments));
      return;
    }
    setState(() => _busy = true);
    try {
      final source = await showAttachMenu(context, files: false);
      if (!mounted || !current() || source == null) return;
      final picker = ref.read(attachmentPickerProvider);
      final picked = switch (source) {
        AttachSource.gallery => await picker.pickImages(limit: room),
        AttachSource.camera => [?(await picker.takePhoto())],
        AttachSource.files => const <DraftAttachment>[],
      };
      for (final image in picked.take(room)) {
        if (!mounted || !current()) return;
        final mediaType = inlineImageType(image.bytes);
        if (mediaType == null) {
          _showProblem(l10n.chatReadImageFailed);
        } else if (image.size > maxImageBytes) {
          _showProblem(l10n.stateAttachmentImageLimit(image.name));
        } else if (image.size <= maxBotImageBytes) {
          _images.add(DraftAttachment(name: image.name, bytes: image.bytes, mediaType: mediaType));
        } else {
          final resized = await compute(fitBotImage, image.bytes);
          if (!mounted || !current()) return;
          if (resized == null) {
            _showProblem(l10n.chatImageTooLarge);
          } else {
            _images.add(DraftAttachment(name: image.name, bytes: resized, mediaType: 'image/jpeg'));
          }
        }
      }
    } catch (_) {
      if (mounted && current()) _showProblem(l10n.chatReadImageFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy || !widget.current() || (_images.isNotEmpty && !widget.sendImages)) return;
    // Keep ordinary text-only sends on their existing optimistic path.
    if (_images.isEmpty) {
      await widget.onSend(const []);
      return;
    }
    setState(() => _busy = true);
    try {
      if (await widget.onSend(List.of(_images)) && mounted) _images.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final attach = widget.sendImages ? AttachButton(onPressed: _busy || !widget.connected ? null : _pick) : null;
    return Composer(
      hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
      controller: widget.controller,
      focusNode: widget.focusNode,
      connected: widget.connected && (_images.isEmpty || widget.sendImages),
      running: widget.running,
      busy: _busy,
      onSend: _send,
      onStop: widget.onStop,
      placeholder: widget.placeholder,
      onKeyEvent: widget.onKeyEvent,
      leading: switch ((attach, widget.mention)) {
        (final add?, final mention?) => Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [add, mention]),
        _ => attach ?? widget.mention,
      },
      accessory: widget.onPickSkill == null
          ? null
          : IconButton(
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(AppIcons.skill, size: 20),
              tooltip: context.l10n.featuresSkills,
              onPressed: _busy || !widget.connected ? null : widget.onPickSkill,
            ),
      hasAttachments: _images.isNotEmpty,
      tray: _images.isEmpty
          ? null
          : ComposerTray(
              items: List.of(_images),
              onRemove: (image) {
                if (!_busy) setState(() => _images.remove(image));
              },
            ),
    );
  }
}
