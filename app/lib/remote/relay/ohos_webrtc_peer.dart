import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter/services.dart';

const _channel = MethodChannel('dsh/ohos-webrtc');
final _peers = <String, _OhosPeer>{};
int _nextId = 0;

/// ArkWeb supplies the ordered DataChannel. Signaling, path selection, Noise
/// and chunking remain with the same RemoteAccount as the other platforms.
Future<remote.RemotePeerConnection> ohosPeerConnector(
  List<remote.RemoteIceServer> servers,
  remote.RemotePeerHandlers handlers,
) async {
  if (_peers.isEmpty) _channel.setMethodCallHandler(_onCall);
  final peer = _OhosPeer('${++_nextId}', handlers);
  _peers[peer.id] = peer;
  try {
    await peer._call<void>('create', {
      'iceServers': [for (final server in servers) server.toJson()],
      'iceTransportPolicy': handlers.iceTransportPolicy.name,
    });
    return peer;
  } catch (_) {
    _peers.remove(peer.id);
    rethrow;
  }
}

Future<void> _onCall(MethodCall call) async {
  if (call.method != 'event') throw MissingPluginException();
  final event = jsonDecode(call.arguments as String) as Map<String, dynamic>;
  final peer = _peers[event['id']];
  if (peer == null) return; // A queued event can outlive its attempt.
  switch (event['type']) {
    case 'ice':
      peer.handlers.onIceCandidate(event['candidate'] as Map<String, dynamic>);
    case 'open':
      peer.handlers.onOpen();
    case 'message':
      peer.handlers.onMessage(base64Decode(event['data'] as String));
    case 'closed':
      _peers.remove(peer.id);
      peer.handlers.onClosed(event['reason'] as String);
  }
}

class _OhosPeer implements remote.RemotePeerConnection {
  _OhosPeer(this.id, this.handlers);
  final String id;
  final remote.RemotePeerHandlers handlers;

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) =>
      _channel.invokeMethod<T>(method, jsonEncode({'id': id, ...args}));

  @override
  Future<String> createOffer(String channelLabel) async {
    if (channelLabel != remote.remoteDataChannelLabel) throw ArgumentError.value(channelLabel, 'channelLabel');
    return (await _call<String>('createOffer'))!;
  }

  @override
  Future<void> setAnswer(String sdp) => _call<void>('setAnswer', {'sdp': sdp});

  @override
  Future<void> addIceCandidate(Map<String, Object?> candidate) =>
      _call<void>('addIceCandidate', {'candidate': candidate});

  @override
  Future<void> send(Uint8List data) => _call<void>('send', {'data': base64Encode(data)});

  @override
  Future<List<Map<String, Object?>>> stats() async =>
      (jsonDecode((await _call<String>('stats'))!) as List).cast<Map<String, Object?>>();

  @override
  Future<void> close() async {
    if (_peers.remove(id) != null) await _call<void>('close');
  }
}
