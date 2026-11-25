import 'dart:convert';

import 'dsbot_api.dart' show DsBotGoLayout;
import 'errors.dart';
import 'features_api.dart' show SettingsOp;
import 'json.dart';
import 'rpc.dart';

/// The independent layout for one authenticated DSH Host profile.
class GoLayoutSettings {
  const GoLayoutSettings._(this.layout, this.revision, {required this.writable});

  /// Null only when this namespace has never saved a layout.
  final DsBotGoLayout? layout;

  /// Settings CAS token. The layout's own revision persists across restarts.
  final int revision;
  final bool writable;
}

class GoLayoutApi {
  const GoLayoutApi(this._rpc);

  static const namespace = 'dsh-go-layout';
  static const _field = 'goLayout';
  final DshRpc _rpc;

  /// A successful description with no matching namespace means unavailable.
  /// Malformed data or failed calls do not establish absence.
  Future<GoLayoutSettings?> describe() async {
    final result = asMap(await _rpc.call('settings/describe'));
    final rows = result?['namespaces'];
    final writable = result?['writable'];
    if (rows is! List || writable is! bool) {
      throw const DshProtocolException('Invalid Go layout settings description');
    }
    GoLayoutSettings? match;
    for (final raw in rows) {
      final row = asMap(raw);
      if (row?['ns'] is! String || (row!['ns'] == namespace && match != null)) {
        throw const DshProtocolException('Invalid Go layout settings namespace');
      }
      if (row['ns'] == namespace) match = _parse(row, writable: writable);
    }
    return match;
  }

  /// Save exactly one field, using the revision of the settings row, and
  /// confirm the Host echoed the complete layout before reporting success.
  Future<GoLayoutSettings> save(GoLayoutSettings expected, DsBotGoLayout layout) async {
    final json = layout.toJson();
    if (!expected.writable || DsBotGoLayout.parse(json, exact: true) == null) {
      throw ArgumentError('Go layout settings are read-only or the layout is invalid');
    }
    final result = asMap(
      await _rpc.call('settings/mutate', {
        'ns': namespace,
        'expectedRevision': expected.revision,
        'ops': [
          SettingsOp.set(const [_field], json).toJson(),
        ],
      }),
    );
    final saved = _parse(result, writable: expected.writable);
    if (saved.revision <= expected.revision || !sameLayout(saved.layout, layout)) {
      throw const DshProtocolException('Host did not acknowledge the Go layout');
    }
    return saved;
  }

  static GoLayoutSettings _parse(Map<String, Object?>? row, {required bool writable}) {
    final value = asMap(row?['value']);
    final revision = row?['revision'];
    if (row?['ns'] != namespace || value == null || !value.containsKey(_field) || revision is! int || revision < 0) {
      throw const DshProtocolException('Invalid Go layout settings namespace');
    }
    final raw = value[_field];
    final layout = DsBotGoLayout.parse(raw, exact: true);
    if (raw != null && layout == null) {
      throw const DshProtocolException('Invalid Go layout settings value');
    }
    return GoLayoutSettings._(layout, revision, writable: writable);
  }

  static bool sameLayout(DsBotGoLayout? a, DsBotGoLayout? b) =>
      identical(a, b) || (a != null && b != null && jsonEncode(a.toJson()) == jsonEncode(b.toJson()));
}
