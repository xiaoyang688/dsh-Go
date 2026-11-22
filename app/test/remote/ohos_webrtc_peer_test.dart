import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/relay/webrtc_peer.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_remote/test/support/fake_remote.dart';
import '../../../packages/dsh_remote/test/support/fake_rtc.dart';

// Exercise the real platform codec, Control socket and Noise session with a
// loopback Host. Only the peer at the ArkWeb side of the channel is simulated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/ohos-webrtc');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeRtcNetwork network;
  late Map<String, RemotePeerConnection> peers;
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;

  Future<void> emit(String id, String type, [Map<String, Object?> args = const {}]) async {
    final event = MethodCall('event', jsonEncode({'id': id, 'type': type, ...args}));
    await messenger.handlePlatformMessage(channel.name, channel.codec.encodeMethodCall(event), (_) {});
  }

  setUp(() async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    network = FakeRtcNetwork();
    peers = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = jsonDecode(call.arguments as String) as Map<String, dynamic>;
      final id = args['id'] as String;
      switch (call.method) {
        case 'create':
          final servers = [
            for (final server in args['iceServers'] as List)
              RemoteIceServer(
                (server['urls'] as List).cast<String>(),
                username: server['username'],
                credential: server['credential'],
              ),
          ];
          peers[id] = await network.connector(
            servers,
            RemotePeerHandlers(
              iceTransportPolicy: RemoteIceTransportPolicy.values.byName(args['iceTransportPolicy'] as String),
              onOpen: () => unawaited(emit(id, 'open')),
              onIceCandidate: (candidate) => unawaited(emit(id, 'ice', {'candidate': candidate})),
              onMessage: (data) => unawaited(emit(id, 'message', {'data': base64Encode(data)})),
              onClosed: (reason) {
                unawaited(peers.remove(id)!.close());
                unawaited(emit(id, 'closed', {'reason': reason}));
              },
            ),
          );
          return null;
        case 'createOffer':
          return peers[id]!.createOffer('dsh');
        case 'setAnswer':
          await peers[id]!.setAnswer(args['sdp'] as String);
        case 'addIceCandidate':
          await peers[id]!.addIceCandidate(args['candidate'] as Map<String, dynamic>);
        case 'send':
          await peers[id]!.send(base64Decode(args['data'] as String));
        case 'stats':
          return jsonEncode(await peers[id]!.stats());
        case 'close':
          await peers.remove(id)!.close();
        default:
          throw MissingPluginException(call.method);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    server = await FakeRemoteServer.start();
    addTearDown(server.close);
    server.webrtc = true;
    server.iceServers = [
      {
        'urls': ['stun:example.test', 'turn:example.test'],
        'username': 'temporary',
        'credential': 'test-only',
      },
    ];
    host = await FakeRemoteHost.start(server)
      ..webrtc = true
      ..rtcNetwork = network;
    addTearDown(host.close);
    await host.goOffline();
    await host.goOnline();
    host.handlers['session/search'] = (args) => {'ok': true, 'value': args};
    account = RemoteAccount(
      secrets: MemorySecretStore(),
      serverUrl: server.url,
      peerConnector: peerConnectorFor('ohos'),
      tryLanFirst: true,
    );
    addTearDown(account.close);
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
  });

  test('a missing native handler still opens a Noise-authenticated relay', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final client = await account.connectHost((await account.listHosts()).single);
    expect(client.remoteCarrier!.state!.transport, 'relay');
    expect(await client.rpc.call('session/search', {'query': 'hello'}), {'query': 'hello'});
    expect(host.handshakes, hasLength(1));
    expect(host.rtcOffers, isEmpty);
  });

  for (final route in ['lan', 'p2p', 'turn', 'relay']) {
    test('HarmonyOS $route completes Noise and a chunked RPC over the selected transport', () async {
      final retry = route == 'turn' || route == 'relay';
      if (route == 'p2p') network.stats = pairStats('srflx', '203.0.113.1', 'host', '192.168.1.1');
      if (retry) network.policyOutcomes[RemoteIceTransportPolicy.all] = FakeRtcOutcome.fail;
      if (route == 'relay') network.policyOutcomes[RemoteIceTransportPolicy.relay] = FakeRtcOutcome.fail;
      const reflexive = 'candidate:8 1 udp 1234 203.0.113.1 40000 typ srflx';
      network.extraLocalCandidates.add({'candidate': reflexive});
      host.extraRtcCandidates.add({'candidate': reflexive});
      host.rtcAnswerSdp += '\r\na=$reflexive\r\n';
      final client = await account.connectHost((await account.listHosts()).single);
      expect(client.remoteCarrier!.state!.transport, route);
      final message = 'payload' * 2400;
      expect(await client.rpc.call('session/search', {'query': message}), {'query': message});
      expect(host.handshakes, hasLength(1));
      expect(server.protocolErrors, isEmpty);
      expect(network.iceServers.first, isEmpty);
      expect(network.clients.first.answer, isNot(contains('typ srflx')));
      expect(network.clients.first.remoteCandidates.map((c) => c['candidate']), isNot(contains(reflexive)));
      if (route == 'lan') {
        expect(network.clients, hasLength(1));
        expect(host.rtcCandidates.values.single, 1);
      } else {
        expect(network.iceServers[1].single.urls, ['stun:example.test']);
        expect(network.iceServers[1].single.credential, isNull);
        expect(network.clients[1].answer, contains('typ srflx'));
      }
      if (retry) {
        expect(network.policies, [
          RemoteIceTransportPolicy.all,
          RemoteIceTransportPolicy.all,
          RemoteIceTransportPolicy.relay,
        ]);
        expect(network.iceServers.last.single.credential, 'test-only');
      }
      if (route != 'relay') {
        expect(network.clients.last.sent, greaterThan(2));
        expect(server.relayFrames + server.controlRelayFrames, 0);
      }
      await client.close();
      expect(peers, isEmpty);
    });
  }
}
