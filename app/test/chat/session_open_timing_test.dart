import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/ui/common/session_open_timing.dart';

void main() {
  testWidgets('only the selected painted body emits one allowlisted sample', (tester) async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      SessionOpenTiming.start('private-selection-key');
      Widget body(String session, SessionBodySource source) =>
          SessionOpenTiming.body(session, source, const Text('private chat text', textDirection: TextDirection.ltr));
      await tester.pumpWidget(body('other-key', SessionBodySource.transcript));
      await tester.pumpWidget(Offstage(child: body('private-selection-key', SessionBodySource.preview)));
      expect(logs, isEmpty);
      await tester.pumpWidget(body('private-selection-key', SessionBodySource.preview));
      await tester.pumpWidget(body('private-selection-key', SessionBodySource.transcript));
      if (SessionOpenTiming.enabled) {
        expect(logs, hasLength(1));
        expect(
          logs.single,
          matches(RegExp(r'^\[DSH_SESSION_OPEN\] scope=drawer_tap_to_body_paint source=preview elapsedMs=\d+$')),
        );
      } else {
        expect(logs, isEmpty);
      }
    } finally {
      debugPrint = previous;
      SessionOpenTiming.start(null);
    }
  });
}
