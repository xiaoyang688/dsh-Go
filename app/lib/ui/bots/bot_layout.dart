import 'dart:async';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bot_layout_state.dart';
import '../../state/bots_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/list_page_row.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart' show AppShape, DshSurfaces, GlassTier;
import 'bot_action_scope.dart';

bool canEditLegacyBotLayout(DsBotStatus status, DsBotApi? api) =>
    status.ready &&
    status.team?.goLayout != null &&
    status.readOnly == null &&
    api != null &&
    (status.feedConnected || api.transport is DsBotUnaryTransport);

bool isBotLayoutConflict(Object error) =>
    error is DshRemoteException && (error.code == 'settings/conflict' || error.code == 'bot/go-layout-conflict');

DshRemoteException _layoutConflict() => DshRemoteException('settings/conflict', 'The Go layout changed');

/// Keep each draft bound to the Host profile, connection generation, and
/// original store. A legacy draft can never become an independent write.
class BotLayoutScope {
  BotLayoutScope(this.owner, this.independent, WidgetRef ref) : bot = BotActionScope(ref);

  final GoLayoutConnection owner;
  final GoLayoutSettings? independent;
  final BotActionScope bot;

  bool connected(BuildContext context, WidgetRef ref) =>
      bot.connected(context, ref) && currentGoLayoutConnection(ref.read) == owner;

  bool changed(AsyncValue<GoLayoutSettings?> settings, DsBotGoLayout? legacy, DsBotGoLayout initial) {
    if (settings is! AsyncData<GoLayoutSettings?>) return false;
    final latest = settings.value;
    return independent == null
        ? latest != null || (legacy != null && legacy.revision > initial.revision)
        : latest == null ||
              latest.revision != independent!.revision ||
              !GoLayoutApi.sameLayout(latest.layout, independent!.layout);
  }

  bool canSave(BuildContext context, WidgetRef ref, AsyncValue<GoLayoutSettings?> settings, DsBotStatus status) =>
      connected(context, ref) &&
      status.ready &&
      !settings.isLoading &&
      settings is AsyncData<GoLayoutSettings?> &&
      (independent != null ? settings.value?.writable == true : canEditLegacyBotLayout(status, bot.api));

  Future<DsBotGoLayout?> save(BuildContext context, WidgetRef ref, DsBotGoLayout draft) async {
    final controller = ref.read(dsBotProvider.notifier);
    final api = ref.read(goLayoutApiProvider)(owner.client);
    final latest = await api.describe();
    if (!context.mounted || !connected(context, ref)) return null;
    final status = ref.read(dsBotProvider);
    if (!status.ready) return null;
    final expected = independent;
    if (expected == null) {
      if (latest != null) throw _layoutConflict();
      if (!canEditLegacyBotLayout(status, bot.api)) return null;
      final saved = await bot.api!.setGoLayout(draft);
      if (!context.mounted || !connected(context, ref)) return null;
      unawaited(controller.refresh());
      return saved;
    }
    if (latest == null ||
        latest.revision != expected.revision ||
        !GoLayoutApi.sameLayout(latest.layout, expected.layout)) {
      throw _layoutConflict();
    }
    final saved = await api.save(
      latest,
      DsBotGoLayout(revision: draft.revision + 1, folders: draft.folders, bots: draft.bots, rooms: draft.rooms),
    );
    if (!context.mounted || !connected(context, ref)) return null;
    ref.invalidate(goLayoutSettingsProvider(owner));
    return saved.layout;
  }
}

typedef _Node = ({String id, String name, bool folder, String? parent});

List<T> _ordered<T>(Iterable<T> items, String Function(T) id, Iterable<String> order) {
  final remaining = {for (final item in items) id(item): item};
  return [for (final key in order) ?remaining.remove(key), ...remaining.values];
}

List<DsBotRoom> orderedBotRooms(List<DsBotRoom> rooms, DsBotGoLayout layout) =>
    _ordered(rooms, (room) => room.id, layout.rooms);

List<DsBotLayoutBot> _orderedBots(List<DsBot> bots, DsBotGoLayout layout) {
  final assignments = {for (final entry in layout.bots) entry.botId: entry.folderId};
  return [
    for (final bot in _ordered(bots, (bot) => bot.id, assignments.keys)) (botId: bot.id, folderId: assignments[bot.id]),
  ];
}

EdgeInsetsGeometry _indent(int depth) => EdgeInsetsDirectional.only(start: min(depth, 5) * 12.0);

/// The organization is navigable even when the Host does not allow edits.
class BotLayoutTree extends StatefulWidget {
  const BotLayoutTree({super.key, required this.layout, required this.bots, required this.buildBot});

  final DsBotGoLayout layout;
  final List<DsBot> bots;
  final Widget Function(DsBot) buildBot;

  @override
  State<BotLayoutTree> createState() => _BotLayoutTreeState();
}

class _BotLayoutTreeState extends State<BotLayoutTree> {
  final _expanded = <String?>{};

  @override
  Widget build(BuildContext context) {
    final folders = <String?, List<DsBotLayoutFolder>>{};
    for (final folder in widget.layout.folders) {
      (folders[folder.parentId] ??= []).add(folder);
    }
    final byId = {for (final bot in widget.bots) bot.id: bot};
    final bots = <String?, List<DsBot>>{};
    for (final entry in _orderedBots(widget.bots, widget.layout)) {
      (bots[entry.folderId] ??= []).add(byId[entry.botId]!);
    }
    Widget folderRow(String? id, String name, int depth) {
      final expanded = _expanded.contains(id);
      return Padding(
        padding: _indent(depth),
        child: Semantics(
          expanded: expanded,
          child: ListPageRow(
            icon: expanded ? AppIcons.folderOpen : AppIcons.folder,
            title: name,
            chevron: false,
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
            onTap: () => setState(() {
              if (!_expanded.remove(id)) _expanded.add(id);
            }),
          ),
        ),
      );
    }

    Iterable<Widget> botRows(String? parent, int depth) => [
      for (final bot in bots[parent] ?? const <DsBot>[]) Padding(padding: _indent(depth), child: widget.buildBot(bot)),
    ];
    List<Widget> children(String? parent, int depth) => [
      for (final folder in folders[parent] ?? const <DsBotLayoutFolder>[]) ...[
        folderRow(folder.id, folder.name, depth),
        if (_expanded.contains(folder.id)) ...children(folder.id, depth + 1),
      ],
      if (parent != null) ...botRows(parent, depth),
    ];
    return Column(
      children: [
        ...children(null, 0),
        if (bots[null]?.isNotEmpty == true) ...[
          folderRow(null, context.l10n.remoteWorkspaceUngrouped, 0),
          if (_expanded.contains(null)) ...botRows(null, 1),
        ],
      ],
    );
  }
}

Future<DsBotGoLayout?> showBotLayoutEditor(
  BuildContext context,
  BotLayoutScope scope,
  DsBotGoLayout layout,
  List<DsBot> bots,
  List<DsBotRoom> rooms,
) {
  return Navigator.of(context).push<DsBotGoLayout>(
    MaterialPageRoute(
      builder: (_) => _BotLayoutEditor(scope: scope, layout: layout, bots: bots, rooms: rooms),
    ),
  );
}

class _BotLayoutEditor extends ConsumerStatefulWidget {
  const _BotLayoutEditor({required this.scope, required this.layout, required this.bots, required this.rooms});

  final BotLayoutScope scope;
  final DsBotGoLayout layout;
  final List<DsBot> bots;
  final List<DsBotRoom> rooms;

  @override
  ConsumerState<_BotLayoutEditor> createState() => _BotLayoutEditorState();
}

enum _Action { up, down, rename, move, remove, addFolder }

class _BotLayoutEditorState extends ConsumerState<_BotLayoutEditor> {
  late final _folders = [...widget.layout.folders];
  late final _bots = _orderedBots(widget.bots, widget.layout);
  late final _rooms = orderedBotRooms(widget.rooms, widget.layout);
  bool _dirty = false;
  bool _saving = false;
  bool _conflict = false;
  String? _error;

  DsBotLayoutFolder _folder(String id) => _folders.firstWhere((entry) => entry.id == id);
  int _depth(String? id) => id == null ? 0 : 1 + _depth(_folder(id).parentId);
  int _height(String id) =>
      1 + _folders.where((entry) => entry.parentId == id).fold(0, (height, entry) => max(height, _height(entry.id)));
  bool _contains(String id, String? candidate) =>
      candidate != null && (candidate == id || _contains(id, _folder(candidate).parentId));
  String _path(DsBotLayoutFolder folder) =>
      [if (folder.parentId case final parent?) _path(_folder(parent)), folder.name].join(' / ');

  void _change(VoidCallback change) => setState(() {
    change();
    _dirty = true;
    _error = null;
  });

  Future<String?> _name(String title, [String initial = '']) {
    var text = initial;
    return showDialog<String>(
      context: context,
      builder: (dialog) {
        final l10n = dialog.l10n;
        return StatefulBuilder(
          builder: (_, update) {
            final valid = DsBotGoLayout.validFolderName(text);
            return AlertDialog(
              title: Text(title),
              content: TextFormField(
                initialValue: initial,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l10n.botsLayoutFolderName,
                  errorText: valid || text.isEmpty ? null : l10n.botsLayoutInvalidName,
                ),
                onChanged: (value) => update(() => text = value),
                onFieldSubmitted: (_) {
                  if (valid) Navigator.pop(dialog, text.trim());
                },
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
                TextButton(
                  onPressed: valid ? () => Navigator.pop(dialog, text.trim()) : null,
                  child: Text(l10n.commonSave),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _addFolder(String? parent) async {
    final name = await _name(context.l10n.botsLayoutNewFolder);
    if (name == null || !mounted) return;
    final random = Random.secure();
    final id = 'f-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _change(() => _folders.add((id: id, name: name, parentId: parent)));
  }

  Future<void> _move(_Node node) async {
    final height = node.folder ? _height(node.id) : 0;
    final destinations = [
      for (final folder in _folders)
        if (folder.id != node.parent &&
            (!node.folder || !_contains(node.id, folder.id)) &&
            _depth(folder.id) + height <= DsBotGoLayout.maxDepth)
          folder,
    ];
    // The record distinguishes cancellation from a selection of the top level.
    final target = await showDialog<({String? id})>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(dialog.l10n.botsLayoutMove),
        children: [
          if (node.parent != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, (id: null as String?)),
              child: Text(dialog.l10n.botsLayoutRoot),
            ),
          for (final folder in destinations)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, (id: folder.id as String?)),
              child: Text(_path(folder)),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    _change(() {
      if (node.folder) {
        _folders.removeWhere((entry) => entry.id == node.id);
        _folders.add((id: node.id, name: node.name, parentId: target.id));
      } else {
        _bots.removeWhere((entry) => entry.botId == node.id);
        _bots.add((botId: node.id, folderId: target.id));
      }
    });
  }

  Future<void> _removeFolder(_Node node) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.l10n.botsLayoutDeleteFolder),
        content: Text(dialog.l10n.botsLayoutDeleteDescription),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: Text(dialog.l10n.commonDelete)),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    _change(() {
      _folders.removeWhere((entry) => entry.id == node.id);
      for (var i = 0; i < _folders.length; i++) {
        final folder = _folders[i];
        if (folder.parentId == node.id) _folders[i] = (id: folder.id, name: folder.name, parentId: node.parent);
      }
      for (var i = 0; i < _bots.length; i++) {
        final bot = _bots[i];
        if (bot.folderId == node.id) _bots[i] = (botId: bot.botId, folderId: node.parent);
      }
    });
  }

  void _step<T>(List<T> entries, T item, T neighbor) {
    if (item == neighbor) return;
    _change(() {
      final a = entries.indexOf(item);
      final b = entries.indexOf(neighbor);
      entries[a] = neighbor;
      entries[b] = item;
    });
  }

  void _reorderBots(String? parent, int from, int to) {
    final slots = [
      for (var i = 0; i < _bots.length; i++)
        if (_bots[i].folderId == parent) i,
    ];
    final siblings = [for (final slot in slots) _bots[slot]];
    _change(() {
      siblings.insert(to, siblings.removeAt(from));
      for (var i = 0; i < slots.length; i++) {
        _bots[slots[i]] = siblings[i];
      }
    });
  }

  Future<void> _apply(_Node node, _Action action, String? neighbor) async {
    switch (action) {
      case _Action.up || _Action.down:
        if (node.folder) {
          _step(_folders, _folder(node.id), _folder(neighbor!));
        } else {
          _step(
            _bots,
            _bots.firstWhere((entry) => entry.botId == node.id),
            _bots.firstWhere((entry) => entry.botId == neighbor),
          );
        }
      case _Action.rename:
        final name = await _name(context.l10n.commonRename, node.name);
        if (name == null || name == node.name || !mounted) return;
        _change(() => _folders[_folders.indexOf(_folder(node.id))] = (id: node.id, name: name, parentId: node.parent));
      case _Action.move:
        await _move(node);
      case _Action.remove:
        await _removeFolder(node);
      case _Action.addFolder:
        await _addFolder(node.id);
    }
  }

  Future<void> _save() async {
    final status = ref.read(dsBotProvider);
    final scope = widget.scope;
    final settings = ref.read(goLayoutSettingsProvider(scope.owner));
    if (_saving ||
        !scope.canSave(context, ref, settings, status) ||
        scope.changed(settings, status.team?.goLayout, widget.layout)) {
      return;
    }
    final layout = DsBotGoLayout(
      revision: widget.layout.revision,
      folders: _folders,
      bots: _bots,
      rooms: _rooms.map((room) => room.id),
    );
    if (DsBotGoLayout.parse(layout.toJson(), exact: true) == null) {
      setState(() => _error = context.l10n.botsLayoutTooLarge);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await scope.save(context, ref, layout);
      if (!mounted || saved == null || !scope.connected(context, ref)) return;
      Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted || !scope.connected(context, ref)) return;
      setState(() {
        _conflict = isBotLayoutConflict(error);
        _error = _conflict ? context.l10n.botsLayoutConflict : describeDsBotError(error);
      });
      if (_conflict || error is DshHttpException || error is DshProtocolException) {
        ref.invalidate(goLayoutSettingsProvider(scope.owner));
        unawaited(ref.read(dsBotProvider.notifier).refresh());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final scope = widget.scope;
    final settings = ref.watch(goLayoutSettingsProvider(scope.owner));
    // Rebuild on changes to the active mux even when the Bot feed stays open.
    ref.watch(goLayoutConnectionProvider);
    final available = scope.canSave(context, ref, settings, status);
    final changed = _conflict || scope.changed(settings, status.team?.goLayout, widget.layout);
    final enabled = available && !changed && !_saving;
    final botNames = {for (final bot in widget.bots) bot.id: bot.name};
    List<Widget> tree(String? parent, int depth) {
      final folders = _folders.where((entry) => entry.parentId == parent).toList();
      final bots = _bots.where((entry) => entry.folderId == parent).toList();
      return [
        for (var i = 0; i < folders.length; i++) ...[
          SliverToBoxAdapter(
            key: ValueKey(folders[i].id),
            child: Material(
              type: MaterialType.transparency,
              child: _nodeRow(
                (id: folders[i].id, name: folders[i].name, folder: true, parent: parent),
                depth,
                enabled,
                i > 0 ? folders[i - 1].id : null,
                i + 1 < folders.length ? folders[i + 1].id : null,
              ),
            ),
          ),
          ...tree(folders[i].id, depth + 1),
        ],
        if (bots.isNotEmpty)
          _reorderableRows(
            key: ValueKey((parent, enabled)),
            count: bots.length,
            onReorder: (from, to) => _reorderBots(parent, from, to),
            row: (i) {
              final id = bots[i].botId;
              return KeyedSubtree(
                key: ValueKey(id),
                child: _nodeRow(
                  (id: id, name: botNames[id]!, folder: false, parent: parent),
                  depth,
                  enabled,
                  i > 0 ? bots[i - 1].botId : null,
                  i + 1 < bots.length ? bots[i + 1].botId : null,
                  dragIndex: enabled && bots.length > 1 ? i : null,
                ),
              );
            },
          ),
      ];
    }

    return PopScope(
      canPop: !_saving,
      child: AppPage(
        title: l10n.botsLayoutEdit,
        slivers: [
          if (!available || changed || _error != null)
            SliverToBoxAdapter(
              child: FeatureNote(
                !available
                    ? l10n.botsLayoutDisconnected
                    : changed
                    ? l10n.botsLayoutConflict
                    : _error!,
              ),
            ),
          _card(l10n.botsGroupChat, [
            _reorderableRows(
              key: ValueKey(enabled),
              count: _rooms.length,
              onReorder: (from, to) => _change(() => _rooms.insert(to, _rooms.removeAt(from))),
              row: (i) => ListPageRow(
                key: ValueKey(_rooms[i].id),
                icon: AppIcons.newGroupChat,
                title: _rooms[i].name,
                trailing: _rowControls(
                  _menu(enabled, [
                    if (i > 0) _Action.up,
                    if (i + 1 < _rooms.length) _Action.down,
                  ], (action) => _step(_rooms, _rooms[i], _rooms[i + (action == _Action.up ? -1 : 1)])),
                  enabled && _rooms.length > 1 ? i : null,
                ),
              ),
            ),
          ]),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          _card('Bot', [
            SliverToBoxAdapter(
              child: Material(
                type: MaterialType.transparency,
                child: ListPageRow(
                  icon: AppIcons.newFolder,
                  title: l10n.botsLayoutNewFolder,
                  chevron: false,
                  onTap: enabled && _folders.length < DsBotGoLayout.maxFolders ? () => _addFolder(null) : null,
                ),
              ),
            ),
            ...tree(null, 0),
          ]),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: enabled && _dirty ? _save : null,
                child: _saving
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> slivers) {
    final surfaces = DshSurfaces.of(context);
    final style = surfaces.glass(GlassTier.card);
    final reduce = !surfaces.blurEnabled || MediaQuery.highContrastOf(context);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(header: true, child: Text(title, style: groupTitleStyle(context))),
            ),
          ),
          DecoratedSliver(
            decoration: ShapeDecoration(
              color: reduce ? style.fallbackFill : style.fill,
              shape: RoundedSuperellipseBorder(
                borderRadius: AppShape.radiusLg,
                side: BorderSide(color: style.hairline, width: style.hairlineWidth),
              ),
            ),
            sliver: SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ),
        ],
      ),
    );
  }

  // Sharing the page's scrollable lets Flutter scroll toward offscreen siblings
  // while keeping room order and each folder's Bot order in separate lists.
  Widget _reorderableRows({
    required Key key,
    required int count,
    required ReorderCallback onReorder,
    required Widget Function(int) row,
  }) => SliverReorderableList(
    key: key,
    itemCount: count,
    onReorderItem: onReorder,
    itemBuilder: (_, i) {
      final child = row(i);
      return Material(key: child.key, type: MaterialType.transparency, child: child);
    },
    proxyDecorator: (child, _, _) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: AppShape.radiusLg,
      child: child,
    ),
  );

  Widget? _rowControls(Widget? menu, int? dragIndex) {
    if (dragIndex == null) return menu;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReorderableDelayedDragStartListener(
          index: dragIndex,
          child: Semantics(
            label: context.l10n.shellDragToReorder,
            child: ColoredBox(
              color: Colors.transparent,
              child: SizedBox.square(
                dimension: 40,
                child: Icon(AppIcons.dragHandle, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
        ?menu,
      ],
    );
  }

  Widget _nodeRow(_Node node, int depth, bool enabled, String? up, String? down, {int? dragIndex}) => Padding(
    padding: _indent(depth),
    child: ListPageRow(
      icon: node.folder ? AppIcons.folder : AppIcons.bot,
      title: node.name,
      trailing: _rowControls(
        _menu(enabled, [
          if (up != null) _Action.up,
          if (down != null) _Action.down,
          if (node.parent != null ||
              _folders.any(
                (f) =>
                    !node.folder ||
                    (!_contains(node.id, f.id) && _depth(f.id) + _height(node.id) <= DsBotGoLayout.maxDepth),
              ))
            _Action.move,
          if (node.folder) ...[
            _Action.rename,
            if (depth + 1 < DsBotGoLayout.maxDepth && _folders.length < DsBotGoLayout.maxFolders) _Action.addFolder,
            _Action.remove,
          ],
        ], (action) => _apply(node, action, action == _Action.up ? up : down)),
        dragIndex,
      ),
    ),
  );

  Widget? _menu(bool enabled, List<_Action> actions, ValueChanged<_Action> onSelected) {
    if (actions.isEmpty) return null;
    final l10n = context.l10n;
    return PopupMenuButton<_Action>(
      tooltip: l10n.botsLayoutActions,
      enabled: enabled,
      icon: const Icon(AppIcons.moreVertical),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final action in actions)
          PopupMenuItem(
            value: action,
            child: Text(switch (action) {
              _Action.up => l10n.botsLayoutUp,
              _Action.down => l10n.botsLayoutDown,
              _Action.move => l10n.botsLayoutMove,
              _Action.rename => l10n.commonRename,
              _Action.addFolder => l10n.botsLayoutNewFolder,
              _Action.remove => l10n.commonDelete,
            }),
          ),
      ],
    );
  }
}
