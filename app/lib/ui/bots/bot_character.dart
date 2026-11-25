// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: character selection and status motion from DS Bot 0.3.10
// characters.js and client.js, rendered to a Flutter canvas.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:path_parsing/path_parsing.dart';

import '../theme/motion.dart';
import 'bot_character_data.dart';

const _defaultShapes = ['star', 'moon', 'gumdrop', 'peanut', 'bunny', 'kitty', 'acorn'];

String botCharacterId(DsBot bot) {
  if (dsBotCharacters.containsKey(bot.shape)) return bot.shape!;
  if (bot.id.isEmpty) return 'gumdrop';
  var value = dsBotFnv1a(bot.id);
  value = ((value ^ (value >>> 16)) * 73244475).toUnsigned(32);
  value = ((value ^ (value >>> 13)) * 3266489909).toUnsigned(32);
  return _defaultShapes[(value ^ (value >>> 16)) % _defaultShapes.length];
}

enum BotAvatarState { idle, thinking, searching, working, sending, orbit, waiting, alert, done }

/// Resolve the avatar from the negotiated live snapshot. A group member tile
/// uses its own room's turn, so work in another room cannot light this one up.
BotAvatarState botAvatarState(DsBotLive live, String botId, {DsBotTeam? team, String? roomId}) {
  final approvals = live.approvals.any((a) => a.botId == botId && a.roomId == roomId);
  final bot = team?.bot(botId);
  if (approvals || (roomId == null && bot != null && team?.questionOf(bot) != null)) return BotAvatarState.alert;
  final work = roomId == null ? live.bots[botId] : live.rooms[roomId]?.where((work) => work.botId == botId).firstOrNull;
  final activity = live.activity[botId];
  if (roomId != null && work == null) return BotAvatarState.idle;
  if (work?.speaking == true) return BotAvatarState.sending;
  if (work != null) {
    return switch (activity) {
      'thinking' => BotAvatarState.thinking,
      'searching' => BotAvatarState.searching,
      'sending' => BotAvatarState.sending,
      'orbit' => BotAvatarState.orbit,
      _ => BotAvatarState.working,
    };
  }
  return activity == 'waiting' ? BotAvatarState.waiting : BotAvatarState.idle;
}

class BotCharacter extends StatelessWidget {
  const BotCharacter({super.key, required this.shape, required this.color, required this.aurora});

  final String shape;
  final Color color;
  final bool aurora;

  @override
  Widget build(BuildContext context) {
    final eyes = _EyeMotion.of(context);
    return CustomPaint(
      painter: _CharacterPainter(shape, color, aurora, eyes?.scale ?? 1, eyes?.offset ?? Offset.zero),
      size: Size.infinite,
    );
  }
}

class _EyeMotion extends InheritedWidget {
  const _EyeMotion({required this.scale, required this.offset, required super.child});

  static _EyeMotion? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_EyeMotion>();

  final double scale;
  final Offset offset;

  @override
  bool updateShouldNotify(_EyeMotion oldWidget) => scale != oldWidget.scale || offset != oldWidget.offset;
}

/// Runs only while the Bot has work, two hops when a question arrives, and a
/// single settling motion when work finishes. Static group portraits have no
/// animation controllers. A photo uses DS Bot's simpler whole-image bob.
class BotCharacterMotion extends StatefulWidget {
  const BotCharacterMotion({
    super.key,
    required this.shape,
    required this.id,
    required this.idleBlink,
    required this.photo,
    required this.state,
    required this.child,
  });

  final String shape;
  final String id;
  final bool idleBlink;
  final bool photo;
  final BotAvatarState state;
  final Widget child;

  @override
  State<BotCharacterMotion> createState() => _BotCharacterMotionState();
}

class _BotCharacterMotionState extends State<BotCharacterMotion> with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this);
  Timer? _idleTimer;
  var _reduced = false;
  late var _pose = widget.state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context) || !TickerMode.valuesOf(context).enabled;
    _animate();
  }

  @override
  void didUpdateWidget(BotCharacterMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) {
      _pose = widget.state == BotAvatarState.idle && oldWidget.state != BotAvatarState.alert && !_reduced
          ? BotAvatarState.done
          : widget.state;
    }
    if (widget.state != oldWidget.state ||
        widget.photo != oldWidget.photo ||
        widget.shape != oldWidget.shape ||
        widget.idleBlink != oldWidget.idleBlink) {
      _animate();
    }
  }

  bool get _wiggle => !widget.photo && const {'star', 'hex', 'plus', 'gem', 'magnet', 'ring'}.contains(widget.shape);
  bool get _squash =>
      !widget.photo && const {'gumdrop', 'peanut', 'cushion', 'squircle', 'moon', 'wave'}.contains(widget.shape);

  void _animate() {
    _idleTimer?.cancel();
    _motion.reset();
    if (_reduced) return;
    if (_pose == BotAvatarState.idle) {
      if (widget.idleBlink && !widget.photo) _scheduleBlink();
      return;
    }
    if (_pose == BotAvatarState.alert || _pose == BotAvatarState.done) {
      _motion.duration = Duration(milliseconds: _pose == BotAvatarState.alert ? 2600 : 1800);
      if (_pose == BotAvatarState.done) {
        _motion.forward().then((_) {
          if (!mounted || _pose != BotAvatarState.done) return;
          setState(() => _pose = BotAvatarState.idle);
          _animate();
        });
      } else {
        _motion.forward();
      }
      return;
    }
    final duration = widget.photo
        ? 1600
        : switch (_pose) {
            BotAvatarState.thinking => 2200,
            BotAvatarState.searching => 1000,
            BotAvatarState.sending => 1100,
            BotAvatarState.waiting || BotAvatarState.orbit => 2600,
            _ => _wiggle ? 1400 : (_squash ? 1200 : 1600),
          };
    _motion.repeat(period: Duration(milliseconds: duration));
  }

  // No idle ticker between blinks. Stagger avatars by ID so a list doesn't
  // blink all at once, and leave photos still as the Web client does.
  void _scheduleBlink() {
    _idleTimer = Timer.periodic(Duration(milliseconds: 1900 + dsBotFnv1a(widget.id) % 1900), (_) {
      _motion.duration = const Duration(milliseconds: 260);
      _motion.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduced || (_pose == BotAvatarState.idle && (!widget.idleBlink || widget.photo))) return widget.child;
    return RepaintBoundary(
      child: AnimatedBuilder(animation: _motion, builder: _frame, child: widget.child),
    );
  }

  Widget _frame(BuildContext context, Widget? child) {
    final t = _motion.value;
    final wave = math.sin(t * math.pi * 2);
    final pulse = (1 - math.cos(t * math.pi * 2)) / 2;
    final state = widget.photo && _pose != BotAvatarState.alert && _pose != BotAvatarState.done
        ? BotAvatarState.working
        : _pose;
    var dx = 0.0, dy = 0.0, angle = 0.0, sx = 1.0, sy = 1.0, eyes = 1.0;
    var gaze = Offset.zero;
    switch (state) {
      case BotAvatarState.idle:
        eyes = 1 - 0.97 * math.sin(math.pi * t);
      case BotAvatarState.thinking:
        dy = -0.03 * pulse;
        angle = 4 + 3 * pulse;
        eyes = 0.7 + 0.08 * pulse;
        gaze = Offset(4 * pulse, -3);
      case BotAvatarState.searching:
        dy = -0.05 * pulse;
        angle = -4 + 3 * pulse;
        gaze = Offset(wave * 9, 0);
      case BotAvatarState.working:
        if (_wiggle) {
          angle = -12 * wave;
          sx = sy = 1 + 0.04 * wave.abs();
        } else if (_squash) {
          sx = 1 + 0.08 * wave;
          sy = 1 - 0.10 * wave;
          dy = -0.04 * math.max(0.0, -wave);
        } else {
          dy = -0.04 * pulse;
          angle = -5 * wave;
        }
        eyes = (1 - math.max(0.0, 1 - (t - 0.46).abs() * 30) * 0.97);
      case BotAvatarState.sending:
        dx = 0.08 * wave;
        angle = 7 * wave;
      case BotAvatarState.orbit || BotAvatarState.waiting:
        angle = -10 * (1 - 2 * pulse);
        gaze = Offset(9 * math.cos(t * math.pi * 2), 6 * wave);
      case BotAvatarState.alert:
        final hop = math.sin(math.pi * math.min(1.0, (t * 2 % 1) / 0.55));
        dy = -0.14 * hop;
        sx = 1 - 0.04 * hop;
        sy = 1 + 0.05 * hop;
      case BotAvatarState.done:
        final settle = t < 0.52 ? math.sin(t * 7 * math.pi) * (1 - t / 0.52) : 0.0;
        sx = 1 + 0.15 * settle;
        sy = 1 - 0.15 * settle;
    }
    return FractionalTranslation(
      translation: Offset(dx, dy),
      child: Transform.rotate(
        angle: angle * math.pi / 180,
        child: Transform.scale(
          scaleX: sx,
          scaleY: sy,
          alignment: Alignment.bottomCenter,
          child: _EyeMotion(scale: eyes, offset: gaze, child: child!),
        ),
      ),
    );
  }
}

class _CharacterPainter extends CustomPainter {
  const _CharacterPainter(this.shape, this.color, this.aurora, this.eyeScale, this.eyeOffset);

  final String shape;
  final Color color;
  final bool aurora;
  final double eyeScale;
  final Offset eyeOffset;

  static final _art = <String, (Path, Path, List<(Path, Paint)>)>{};
  static final _shade = Paint()..color = const Color(0x12000000);
  static final _aurora = ui.Gradient.linear(
    const Offset(18, 10),
    const Offset(78, 92),
    const [Color(0xffa4ffb0), Color(0xff00f0e4), Color(0xff2e9ef7)],
    const [0, 0.42, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final def = dsBotCharacters[shape]!;
    final (body, shade, paints) = _art.putIfAbsent(
      shape,
      () => (
        _path(def.body),
        _path(def.shade),
        [
          for (final (data, color, opacity) in def.paints)
            (_path(data), Paint()..color = Color(color).withValues(alpha: opacity)),
        ],
      ),
    );
    final eyes = Path();
    for (final (cx, cy, w, h, tilt) in def.eyes) {
      final center = Offset(cx, cy) + eyeOffset;
      final eye = Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: w, height: h * eyeScale),
            Radius.circular(w / 2),
          ),
        );
      eyes.addPath(
        eye,
        Offset.zero,
        matrix4:
            (Matrix4.identity()
                  ..setTranslationRaw(center.dx, center.dy, 0)
                  ..rotateZ(tilt * math.pi / 180))
                .storage,
      );
    }
    canvas.save();
    canvas.scale(size.width / 100);
    // The Web SVG masks the eyes through every layer. Cutting them out keeps
    // the same transparent face on both light and dark surfaces.
    final silhouette = Path.combine(PathOperation.difference, body, eyes);
    canvas.drawPath(silhouette, aurora ? (Paint()..shader = _aurora) : (Paint()..color = color));
    for (final (path, paint) in paints) {
      canvas.drawPath(Path.combine(PathOperation.difference, path, eyes), paint);
    }
    canvas.drawPath(Path.combine(PathOperation.difference, shade, eyes), _shade);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CharacterPainter oldDelegate) =>
      shape != oldDelegate.shape ||
      color != oldDelegate.color ||
      aurora != oldDelegate.aurora ||
      eyeScale != oldDelegate.eyeScale ||
      eyeOffset != oldDelegate.eyeOffset;
}

Path _path(String data) {
  final proxy = _PathProxy();
  writeSvgPathDataToPath(data, proxy);
  return proxy.path;
}

class _PathProxy implements PathProxy {
  final path = Path()..fillType = PathFillType.evenOdd;

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
  @override
  void lineTo(double x, double y) => path.lineTo(x, y);
  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) =>
      path.cubicTo(x1, y1, x2, y2, x3, y3);
  @override
  void close() => path.close();
}
