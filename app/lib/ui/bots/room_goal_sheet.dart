import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';
import 'bot_action_scope.dart';

String roomGoalStatus(L10n l10n, DsBotRoomGoal goal) => switch (goal.status) {
  DsBotGoalStatus.drafting => l10n.botsGoalDrafting,
  DsBotGoalStatus.active => goal.idle ? l10n.botsGoalWaiting : l10n.botsGoalActive,
  DsBotGoalStatus.paused => l10n.botsGoalPaused,
  DsBotGoalStatus.complete => l10n.botsGoalComplete,
  DsBotGoalStatus.stopped => l10n.botsGoalStopped,
};

Future<void> showRoomGoalSheet(BuildContext context, BotActionScope scope) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => _RoomGoalSheet(scope: scope),
);

class _RoomGoalSheet extends ConsumerStatefulWidget {
  const _RoomGoalSheet({required this.scope});

  final BotActionScope scope;

  @override
  ConsumerState<_RoomGoalSheet> createState() => _RoomGoalSheetState();
}

class _RoomGoalSheetState extends ConsumerState<_RoomGoalSheet> {
  final _brief = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  DsBotRoom? get _currentRoom => ref.read(dsBotProvider).team?.room(widget.scope.roomId);

  Future<void> _mutate(DsBotRoomGoal? expected, Future<void> Function(DsBotApi) call) async {
    final scope = widget.scope;
    if (_busy || !scope.current(context, ref)) return;
    final goal = _currentRoom?.goal;
    if (goal?.id != expected?.id || goal?.status != expected?.status) {
      setState(() => _error = context.l10n.botsGoalChanged);
      return;
    }
    final hub = ref.read(dsBotProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await call(scope.api!);
      if (mounted && scope.connected(context, ref)) _brief.clear();
    } catch (error) {
      if (mounted && scope.connected(context, ref)) _error = describeDsBotError(error);
    } finally {
      // A Host can save the goal before its follow-up (such as interrupting work) fails.
      if (mounted && scope.connected(context, ref)) await hub.refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _control(DsBotRoomGoal goal, DsBotGoalAction action) async {
    if (action == DsBotGoalAction.stop) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(dialog.l10n.botsGoalStop),
          content: Text(dialog.l10n.botsGoalStopWarning),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(dialog.l10n.botsGoalStop)),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _mutate(goal, (api) => api.controlRoomGoal(widget.scope.roomId!, goal.id, action));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final room = status.team?.room(widget.scope.roomId);
    final connected = widget.scope.connected(context, ref);
    final writable = connected && status.readOnly == null;
    final goal = room?.goal;
    final controls = switch (goal?.status) {
      DsBotGoalStatus.drafting || DsBotGoalStatus.complete || DsBotGoalStatus.stopped => [DsBotGoalAction.clear],
      DsBotGoalStatus.active => [DsBotGoalAction.pause, DsBotGoalAction.stop],
      DsBotGoalStatus.paused => [DsBotGoalAction.resume, DsBotGoalAction.stop],
      null => const <DsBotGoalAction>[],
    };
    final padding = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: padding),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - padding) * .85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetTitleBar(connected && writable && goal == null ? l10n.botsGoalSet : l10n.botsGroupGoal),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      if (!connected || room == null)
                        Text(l10n.botsGoalUnavailable)
                      else if (goal == null) ...[
                        if (!writable)
                          Text(l10n.commonNotSet)
                        else if (room.admin == null)
                          Text(l10n.botsGoalNeedsAdmin)
                        else ...[
                          Text(l10n.botsGoalDraftHint),
                          TextField(
                            key: const ValueKey('room-goal-brief'),
                            controller: _brief,
                            enabled: !_busy,
                            minLines: 2,
                            maxLines: 4,
                            maxLength: 2000,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(labelText: l10n.botsGoalPrompt),
                          ),
                          FilledButton(
                            onPressed: _busy || _brief.text.trim().isEmpty || _brief.text.trim().length > 2000
                                ? null
                                : () async {
                                    FocusScope.of(context).unfocus();
                                    final text = _brief.text.trim();
                                    await _mutate(null, (api) => api.draftRoomGoal(room.id, text));
                                  },
                            child: Text(l10n.botsGoalSend),
                          ),
                        ],
                      ] else ...[
                        _GoalDetails(goal: goal, team: status.team!),
                        if (writable)
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final action in controls)
                                OutlinedButton(
                                  key: ValueKey('room-goal-${action.name}'),
                                  onPressed: _busy ? null : () => _control(goal, action),
                                  style: action == DsBotGoalAction.stop
                                      ? OutlinedButton.styleFrom(foregroundColor: DshColors.of(context).danger)
                                      : null,
                                  child: Text(switch (action) {
                                    DsBotGoalAction.pause => l10n.botsGoalPause,
                                    DsBotGoalAction.resume => l10n.botsGoalResume,
                                    DsBotGoalAction.stop => l10n.botsGoalStop,
                                    DsBotGoalAction.clear =>
                                      goal.status == DsBotGoalStatus.drafting
                                          ? l10n.botsGoalCancelDraft
                                          : l10n.botsGoalClear,
                                  }),
                                ),
                            ],
                          ),
                      ],
                      if (_busy) const LinearProgressIndicator(),
                      if (_error case final error? when connected)
                        Text(error, style: TextStyle(color: DshColors.of(context).danger)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalDetails extends StatelessWidget {
  const _GoalDetails({required this.goal, required this.team});

  final DsBotRoomGoal goal;
  final DsBotTeam team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(roomGoalStatus(l10n, goal), style: theme.textTheme.labelLarge),
        if (goal.status == DsBotGoalStatus.drafting) ...[
          if (goal.brief case final brief?) Text(brief),
          Text(l10n.botsGoalDraftHint),
        ] else ...[
          if (goal.title.isNotEmpty) Text(goal.title, style: theme.textTheme.titleLarge),
          if (goal.objective case final text? when text.isNotEmpty) Text(text),
          if (goal.acceptance case final text? when text.isNotEmpty) Text(l10n.botsGoalDoneWhen(text)),
          for (final rule in goal.constraints) Text('• $rule'),
          if (goal.summary case final text? when text.isNotEmpty) Text(text),
          if (goal.evidence case final text? when text.isNotEmpty) Text(l10n.botsGoalEvidence(text)),
          if (goal.reason case final text? when text.isNotEmpty) Text(text),
          for (final (index, stage) in goal.stages.indexed)
            ExpansionTile(
              dense: true,
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: index == goal.current,
              key: ValueKey((goal.id, index)),
              leading: stage.status == 'passed' ? const Icon(Icons.check_circle_outline) : null,
              title: Text('${index + 1}. ${stage.title}'),
              subtitle: index == goal.current ? Text(l10n.botsGoalCurrentStage) : null,
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (stage.acceptance case final text? when text.isNotEmpty) Text(l10n.botsGoalDoneWhen(text)),
                if (stage.feedback case final text? when text.isNotEmpty) Text(l10n.botsGoalFeedback(text)),
                if (stage.evidence case final text? when text.isNotEmpty) Text(l10n.botsGoalEvidence(text)),
                for (final task in stage.tasks)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(task.text),
                    subtitle: Text(
                      [
                        if (team.bot(task.botId) case final bot?) bot.name,
                        switch (task.status) {
                          'working' => l10n.botsWorking,
                          'reported' => l10n.botsGoalTaskReported,
                          'done' => l10n.botsGoalComplete,
                          _ => l10n.botsGoalTaskPending,
                        },
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}
