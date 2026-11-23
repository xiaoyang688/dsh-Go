import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum SessionBodySource { preview, transcript }

/// Device benchmark only. The in-memory selection key is never logged. Timing
/// ends in Flutter paint, before rasterization, display scanout and any
/// remaining drawer-close animation.
abstract final class SessionOpenTiming {
  static const enabled = bool.fromEnvironment('DSH_SESSION_OPEN_TIMING');
  static String? _target;
  static final _watch = Stopwatch();

  static void start(String? target) {
    if (!enabled) return;
    _target = target;
    _watch.stop();
    _watch.reset();
    if (target != null) _watch.start();
  }

  static Widget body(String? session, SessionBodySource source, Widget child) {
    if (!enabled || session == null || session != _target) return child;
    return _BodyPaint(session: session, source: source, child: child);
  }
}

class _BodyPaint extends SingleChildRenderObjectWidget {
  const _BodyPaint({required this.session, required this.source, required super.child});
  final String session;
  final SessionBodySource source;

  @override
  _RenderBodyPaint createRenderObject(BuildContext context) => _RenderBodyPaint(session, source);

  @override
  void updateRenderObject(BuildContext context, _RenderBodyPaint renderObject) {
    renderObject.session = session;
    renderObject.source = source;
  }
}

class _RenderBodyPaint extends RenderProxyBox {
  _RenderBodyPaint(this.session, this.source);
  String session;
  SessionBodySource source;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (session != SessionOpenTiming._target || size.isEmpty) return;
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport != null &&
        !MatrixUtils.transformRect(getTransformTo(viewport), paintBounds).overlaps(viewport.paintBounds)) {
      return;
    }
    SessionOpenTiming._watch.stop();
    SessionOpenTiming._target = null;
    debugPrint('[DSH_SESSION_OPEN] scope=drawer_tap_to_body_paint source=${source.name} '
        'elapsedMs=${SessionOpenTiming._watch.elapsedMilliseconds}');
  }
}
