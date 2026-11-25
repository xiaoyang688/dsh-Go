// Hooks the shell wires in: keep DS Bot's
// notifications alive with the shell, and open a Bot or group from a tapped
// notification.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/bots_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import 'bot_chat_page.dart';
import 'room_chat_page.dart';

/// Keeps the inbox alive so notices become notifications. The controller
/// observes the app foreground flag already maintained by the shell.
class BotAlertsHost extends ConsumerWidget {
  const BotAlertsHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(dsBotInboxProvider.select((_) => null));
    return const SizedBox.shrink();
  }
}

/// Opens the Bot or group a tapped notification names; false for any other
/// notification, which the chat handles.
bool openDsBotTap(BuildContext context, NotifyTap tap) {
  final kind = tap.kind;
  if (kind != dsBotTapBot && kind != dsBotTapRoom) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(activeHostProvider.notifier).select(tap.host);
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(kind == dsBotTapRoom ? RoomChatPage.route(tap.sessionId) : BotChatPage.route(tap.sessionId));
  return true;
}
