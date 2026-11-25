import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/relay/https_host_link.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';

class _SocketBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _SocketBinding();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  HttpsFirstHostLink link(FakeRelayBackend relay, Future<Uri?> url) {
    final result = HttpsFirstHostLink(
      fallback: RelayHostLink(backend: relay, hostId: 'mac', resolveHost: () async => sampleRelayHosts.first),
      launchUrl: url,
    );
    addTearDown(result.close);
    return result;
  }

  test('unconfigured link retains the actual LAN fallback status', () async {
    final relay = FakeRelayBackend(user: sampleRelayUser)..path = RelayPath.lan;
    final subject = link(relay, Future.value());
    final client = await subject.open();
    expect(subject.currentClient, same(client));
    expect(subject.status.path, RelayPath.lan);
    expect(subject.status.network?.safeFallbackReason, isNull);
    expect(relay.connected, ['mac']);
  });

  test('HTTPS fails before publication when the peer only supports cleartext', () async {
    // Use a real socket. Sending TLS records to a cleartext-only endpoint must
    // not send any HTTP authorization to that endpoint or publish its client.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    server.listen((request) async {
      methods.add(request.method);
      await request.response.close();
    });
    final relay = FakeRelayBackend(user: sampleRelayUser)..path = RelayPath.p2p;
    final subject = link(relay, Future.value(Uri.parse('https://127.0.0.1:${server.port}/?token=test-only')));
    final connected = <RelayPath?>[];
    final listener = subject.statuses.where((s) => s.isConnected).listen((s) => connected.add(s.path));
    addTearDown(listener.cancel);

    expect(await subject.open(), same(subject.fallback.currentClient));
    expect(connected, [RelayPath.p2p]);
    expect(subject.status.network?.safeFallbackReason, 'httpsUnavailable');
    expect(relay.connected, ['mac']);
    expect(methods, isEmpty);
  });

  test('TLS login waits for mux readiness and a later loss stays on HTTPS', () async {
    // The checked-in PEM is a dedicated loopback test certificate and key.
    final pem = File('test/remote/fixtures/https_loopback.pem');
    final serverContext = SecurityContext()
      ..useCertificateChain(pem.path)
      ..usePrivateKey(pem.path);
    final fixtureCertificate = RegExp(r'-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----')
        .firstMatch(await pem.readAsString())!
        .group(0)!;
    String normalizePem(String value) => value.replaceAll(RegExp(r'\s'), '');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
    addTearDown(() => server.close(force: true));
    final opened = Completer<void>();
    final allowReady = Completer<void>();
    final sockets = <WebSocket>[];
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path == '/dsh/') {
        expect(request.uri.queryParameters['token'], 'test-only');
        request.response.statusCode = 303;
        request.response.headers.set('location', './');
        request.response.cookies.add(Cookie('dsh-auth-fixture', 'test-cookie'));
        await request.response.close();
        return;
      }
      expect(request.uri.path, '/dsh/api/remote.mux');
      expect(request.headers.value('cookie'), 'dsh-auth-fixture=test-cookie');
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) async {
        final frame = jsonDecode(data as String) as Map;
        if (frame['endpoint'] != r'$events') return;
        if (!opened.isCompleted) opened.complete();
        await allowReady.future;
        socket.add(
          jsonEncode({
            'type': 'item',
            'streamId': frame['streamId'],
            'value': {
              'type': 'ready',
              'clientId': 'test-only',
              'host': {'home': '/tmp'},
            },
          }),
        );
      });
    });
    final relay = FakeRelayBackend(user: sampleRelayUser);
    final subject = link(relay, Future.value(Uri.parse('https://127.0.0.1:${server.port}/dsh/?token=test-only')));
    final defaultZone = Zone.current;
    final opening = HttpOverrides.runZoned(
      subject.open,
      // Match the loopback fixture's exact certificate. Test override only;
      // macOS does not trust this local fixture via a private SecurityContext.
      createHttpClient: (_) => defaultZone.run(
        () => HttpClient()
          ..badCertificateCallback = (certificate, host, port) =>
              host == '127.0.0.1' &&
              port == server.port &&
              normalizePem(certificate.pem) == normalizePem(fixtureCertificate),
      ),
    );
    opening.ignore();
    const guard = Duration(seconds: 5);
    await opened.future.timeout(guard, onTimeout: () => fail('No event upgrade. Request paths: $requests'));
    expect(subject.currentClient, isNull);
    expect(relay.connected, isEmpty);
    allowReady.complete();
    final client = await opening.timeout(guard);
    expect(subject.currentClient, same(client));
    expect(subject.status.path, RelayPath.https);
    final next = client.mux.generations.first;
    await sockets.first.close();
    expect((await next.timeout(guard)).number, 2);
    expect(subject.currentClient, same(client));
    expect(relay.connected, isEmpty);
    expect(requests, ['/dsh/', '/dsh/api/remote.mux', '/dsh/api/remote.mux']);
  });

  test('closing during secure storage resolution prevents any fallback publication', () async {
    final relay = FakeRelayBackend(user: sampleRelayUser);
    final configured = Completer<Uri?>();
    final subject = link(relay, configured.future);
    final opening = expectLater(subject.open(), throwsA(isA<DshClosedException>()));
    await subject.close();
    configured.complete(Uri.parse('https://127.0.0.1:1/?token=test-only'));
    await opening;
    expect(relay.connected, isEmpty);
  });

  test('changing a Remote route clears the previous writable selection and retains host identity', () async {
    const host = HostRef.relay('mac');
    final relay = FakeRelayBackend(user: sampleRelayUser);
    var config = Future<Uri?>.value();
    final container = ProviderContainer(
      overrides: [
        relayBackendProvider.overrideWithValue(relay),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        remoteHttpsLaunchUrlProvider(host.id).overrideWith((_) => config),
      ],
    );
    addTearDown(container.dispose);
    final selection = container.listen(activeHostProvider, (_, _) {});
    addTearDown(selection.close);
    await container.read(activeHostProvider.notifier).ready;
    container.read(activeHostProvider.notifier).select(host);
    final observed = container.listen(activeConnectionProvider, (_, _) {});
    addTearDown(observed.close);
    final first = (await container.read(remoteConnectionProvider(host).future))!;
    expect(first.kind, HostKind.relay);
    expect(first.hostId, host.id);
    expect(first.isLocal, isFalse);

    final pending = Completer<Uri?>();
    config = pending.future;
    container.invalidate(remoteHttpsLaunchUrlProvider(host.id));
    await container.pump();
    expect(container.read(activeConnectionProvider).value, isNull);
    pending.complete(null);
    final replacement = (await container.read(remoteConnectionProvider(host).future))!;
    expect(replacement.hostId, host.id);
    expect(replacement.client, isNot(same(first.client)));
    expect(relay.closedClients, contains(first.client));
  });
}
