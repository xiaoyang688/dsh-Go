// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: DS Bot 0.3.10 RoomAvatar cluster adapted to Flutter.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import '../common/display_image.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_character.dart';
import 'bot_format.dart';

export 'bot_character.dart' show BotAvatarState, botAvatarState;

/// The Bot's color for the current theme.
Color botInk(BuildContext context, String color) =>
    Color(dsBotInkArgb(color, dark: Theme.of(context).brightness == Brightness.dark));

/// Name text in the Bot's color: black reads as a heading, so it goes gray.
Color botNameInk(BuildContext context, String color) => botInk(context, color == 'black' ? 'gray' : color);

/// The team's selected photo or character, with the status outside the face.
class BotAvatar extends ConsumerWidget {
  const BotAvatar({
    super.key,
    required this.bot,
    this.size = 40,
    this.state,
    this.working = false,
    this.main = false,
    this.badge = true,
    this.live = false,
  });

  final DsBot bot;
  final double size;
  final BotAvatarState? state;
  final bool working;
  final bool main;
  final bool badge;
  final bool live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageRef = bot.imageRef;
    final photo = imageRef == null ? null : ref.watch(dsBotPhotoProvider((botId: bot.id, ref: imageRef))).value;
    final shape = botCharacterId(bot);
    final fallback = BotCharacter(shape: shape, color: botInk(context, bot.ink), aurora: bot.ink == 'aurora');
    final face = photo == null
        ? fallback
        : ClipOval(
            child: Image(
              image: imageForDisplay(
                MemoryImage(photo),
                width: size,
                height: size,
                pixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, _, _) => fallback,
            ),
          );
    final pose = state ?? (working ? BotAvatarState.working : BotAvatarState.idle);
    final active = pose != BotAvatarState.idle && pose != BotAvatarState.waiting && pose != BotAvatarState.done;
    final animate = live || state != null || working;
    final mark = animate
        ? BotCharacterMotion(
            key: ValueKey(bot.id),
            id: bot.id,
            idleBlink: live,
            shape: shape,
            photo: photo != null,
            state: pose,
            child: face,
          )
        : face;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            mark,
            if (badge && (active || main))
              Positioned(
                right: 0,
                bottom: 0,
                child: _BotBadge(size: size, active: active, alert: pose == BotAvatarState.alert),
              ),
          ],
        ),
      ),
    );
  }
}

class _BotBadge extends StatelessWidget {
  const _BotBadge({required this.size, required this.active, required this.alert});

  final double size;
  final bool active;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = DshSurfaces.of(context).backdropTop;
    final extent = alert ? (size * 0.3).clamp(10.0, 14.0) : (size * 0.21).clamp(5.0, 9.0);
    if (!active) {
      return Icon(Icons.star_rounded, size: (size * 0.36).clamp(14.0, 22.0), color: const Color(0xffeab44e));
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: alert ? theme.colorScheme.primary : const Color(0xff10b981),
        shape: BoxShape.circle,
        border: Border.all(color: surface, width: 1.25),
      ),
      child: SizedBox.square(
        dimension: extent,
        child: alert
            ? Center(
                child: Text(
                  '?',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: extent * .71,
                    height: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// The initial on a soft tint of the Bot's color, centered optically.
class BotMonogram extends StatelessWidget {
  const BotMonogram({super.key, required this.name, required this.color, this.size = 40});

  final String name;
  final String color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = botInk(context, color);
    final text = botNameInk(context, color);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: ink.withValues(alpha: dark ? 0.26 : 0.16),
          shape: const CircleBorder(),
        ),
        child: Center(
          child: Text(
            monogramOf(name),
            textScaler: TextScaler.noScaling,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: size * 0.42,
              height: 1,
              fontWeight: FontWeight.w600,
              color: text,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}

/// The team's group portrait. Beyond four members, the last seat counts the
/// members that don't fit, as in DS Bot's Web client.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({super.key, required this.room, required this.team, this.size = 40});

  final DsBotRoom room;
  final DsBotTeam team;
  final double size;

  @override
  Widget build(BuildContext context) {
    final members = [for (final id in room.members.toSet()) ?team.bot(id)];
    if (members.isEmpty) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
            shape: const CircleBorder(),
          ),
          child: Icon(AppIcons.groupChat, size: size * 0.5, color: DshColors.of(context).textTertiary),
        ),
      );
    }
    final seats = switch (members.length) {
      1 || 2 => [
        Rect.fromLTWH(0, 0, size * 2 / 3, size * 2 / 3),
        Rect.fromLTWH(size / 3, size / 3, size * 2 / 3, size * 2 / 3),
      ],
      3 => [
        Rect.fromLTWH(size * 2 / 9, 0, size * 5 / 9, size * 5 / 9),
        Rect.fromLTWH(0, size * 4 / 9, size * 5 / 9, size * 5 / 9),
        Rect.fromLTWH(size * 4 / 9, size * 4 / 9, size * 5 / 9, size * 5 / 9),
      ],
      _ => [
        for (var i = 0; i < 4; i++) Rect.fromLTWH(i.isOdd ? size / 2 : 0, i >= 2 ? size / 2 : 0, size / 2, size / 2),
      ],
    };
    final overflow = members.length > 4 ? members.length - 3 : 0;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            for (var i = 0; i < seats.length; i++)
              Positioned.fromRect(
                rect: seats[i],
                child: ClipPath(
                  clipper: _SeatClipper(seats[i].topLeft, seats.skip(i + 1).toList(), size / 14),
                  child: overflow > 0 && i == 3
                      ? _RoomAvatarSeat(label: '+$overflow', size: seats[i].width)
                      : i >= members.length
                      ? _RoomAvatarSeat(size: seats[i].width)
                      : BotAvatar(key: ValueKey(members[i].id), bot: members[i], size: seats[i].width, badge: false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoomAvatarSeat extends StatelessWidget {
  const _RoomAvatarSeat({this.label, required this.size});

  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(size * 0.04),
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
        shape: const CircleBorder(),
      ),
      child: label == null
          ? null
          : Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label!,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: (size * 0.36).clamp(8.0, 16.0)),
                ),
              ),
            ),
    ),
  );
}

/// Leaves gaps behind overlapping faces without adding a background ring.
class _SeatClipper extends CustomClipper<Path> {
  const _SeatClipper(this.origin, this.front, this.gap);

  final Offset origin;
  final List<Rect> front;
  final double gap;

  @override
  Path getClip(Size size) {
    var clip = Path()..addRect(Offset.zero & size);
    for (final face in front) {
      final circle = Rect.fromCircle(center: face.center - origin, radius: face.width * .48 + gap);
      if (circle.overlaps(Offset.zero & size)) {
        clip = Path.combine(PathOperation.difference, clip, Path()..addOval(circle));
      }
    }
    return clip;
  }

  @override
  bool shouldReclip(_SeatClipper old) => old.origin != origin || old.gap != gap || !listEquals(old.front, front);
}
