import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'read_list_identity.dart';
import 'workspaces_state.dart';

typedef HistoryPreviewScope = (ReadListIdentity, String?);
typedef HistoryPreviewLine = ({bool user, String text});

final historyPreviewScopeProvider = Provider<HistoryPreviewScope?>((ref) {
  final identity = ref.watch(readListIdentityProvider);
  if (identity == null) return null;
  final workspace = ref.watch(workspacePrefsProvider.select((p) => (p.loaded, p.selected)));
  return workspace.$1 ? (identity, workspace.$2) : null;
});

/// Process memory only. A scope change discards the whole cache. Entries
/// contain up to six durable text excerpts, never a transcript or action IDs.
class HistoryPreviewCache {
  static const sessions = 12, lines = 6, characters = 256;
  final _entries = <String, List<HistoryPreviewLine>>{};

  List<HistoryPreviewLine> read(String id) => _entries[id] ?? const [];
  void forget(String id) => _entries.remove(id);

  void remember(String id, List<ChatItem> items) {
    final result = <HistoryPreviewLine>[];
    for (final item in items.reversed.take(32)) {
      final text = switch (item) {
        UserChatItem(sourceKind: 'user', :final text) => text,
        AssistantChatItem(streaming: false, seq: final seq?, :final text) when seq >= 0 => text,
        _ => '',
      };
      final excerpt = String.fromCharCodes(text.runes.take(characters)).trim();
      if (excerpt.isEmpty) continue;
      result.add((user: item is UserChatItem, text: excerpt));
      if (result.length == lines) break;
    }
    forget(id);
    if (result.isEmpty) return;
    _entries[id] = List.unmodifiable(result.reversed);
    if (_entries.length > sessions) forget(_entries.keys.first);
  }
}

final historyPreviewCacheProvider = Provider<HistoryPreviewCache?>((ref) {
  return ref.watch(historyPreviewScopeProvider) == null ? null : HistoryPreviewCache();
});
