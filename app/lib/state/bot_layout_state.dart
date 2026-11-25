import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'connection_state.dart';
import 'hosts_state.dart';
import 'read_list_identity.dart';

final goLayoutApiProvider = Provider<GoLayoutApi Function(DshClient)>(
  (ref) =>
      (client) => GoLayoutApi(client.rpc),
);

typedef GoLayoutConnection = ({DshClient client, MuxGeneration? generation});

GoLayoutConnection? currentGoLayoutConnection(WidgetOrProviderRead read) {
  final connection = readListConnection(read(activeConnectionProvider), read(activeHostProvider));
  if (connection == null) return null;
  final client = connection.client;
  final mux = client.mux;
  if (mux.state == DshConnectionState.reconnecting ||
      mux.state == DshConnectionState.unauthorized ||
      mux.state == DshConnectionState.closed) {
    return null;
  }
  return (client: client, generation: mux.generation);
}

typedef WidgetOrProviderRead = T Function<T>(ProviderListenable<T> provider);

final goLayoutConnectionProvider = Provider.autoDispose<GoLayoutConnection?>((ref) {
  final connection = readListConnection(ref.watch(activeConnectionProvider), ref.watch(activeHostProvider));
  if (connection == null) return null;
  final sub = connection.client.mux.states.listen((_) => ref.invalidateSelf());
  ref.onDispose(() => unawaited(sub.cancel()));
  return currentGoLayoutConnection(ref.read);
});

/// Family ownership prevents a previous client's layout from resurfacing when
/// Riverpod carries last-known data through a refresh.
final goLayoutSettingsProvider = FutureProvider.autoDispose.family<GoLayoutSettings?, GoLayoutConnection>((ref, owner) {
  final sub = owner.client.hostEvents.listen((event) {
    if (event is SettingsUpdatedEvent && event.namespace == GoLayoutApi.namespace) ref.invalidateSelf();
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  return ref.read(goLayoutApiProvider)(owner.client).describe();
}, retry: (_, _) => null);
