import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _RecordingClient implements HttpClient {
  final requests = <(Uri, _Request)>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = _Request();
    requests.add((url, request));
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  set connectionTimeout(Duration? value) {}
  @override
  set idleTimeout(Duration value) {}
  @override
  set autoUncompress(bool value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async => throw const HttpException('fixture');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final base = Uri.parse('https://example.test/dsh/');

  test('dedicated HTTPS requires a clean HTTPS mount and disables background reads', () {
    for (final invalid in [
      'http://example.test/dsh/',
      'https://name@example.test/dsh/',
      'https://example.test/dsh/?token=fixture',
      'https://example.test/dsh/#fragment',
    ]) {
      expect(() => DshConnection(Uri.parse(invalid), strictHttps: true), throwsArgumentError);
    }
    final connection = DshConnection(base, strictHttps: true);
    addTearDown(connection.close);
    expect(connection.resolve('/api/bot'), Uri.parse('https://example.test/dsh/api/bot'));
    expect(connection.webSocketUri('/api/remote.mux'), Uri.parse('wss://example.test/dsh/api/remote.mux'));
    expect(connection.canReadSessionsInBackground, isFalse);
    expect(() => connection.resolve('/../other'), throwsA(isA<DshProtocolException>()));
    expect(() => connection.resolve('/..\\other'), throwsA(isA<DshProtocolException>()));
    connection.cookie = const DshCookie(name: 'dsh-auth-fixture', value: 'fixture', authority: 'elsewhere.test');
    expect(() => connection.resolve('/api/bot'), throwsA(isA<DshProtocolException>()));
  });

  test('dedicated HTTPS disables redirect following for HTTP and WebSocket upgrades', () async {
    final recording = _RecordingClient();
    final connection = HttpOverrides.runZoned(
      () => DshConnection(base, strictHttps: true),
      createHttpClient: (_) => recording,
    );
    addTearDown(connection.close);
    await expectLater(connection.get('/api/bot'), throwsA(isA<DshTransportException>()));
    await expectLater(connection.connectWebSocket('/api/remote.mux'), throwsA(isA<DshTransportException>()));
    expect(recording.requests.map((entry) => entry.$1.path), ['/dsh/api/bot', '/dsh/api/remote.mux']);
    expect(recording.requests.map((entry) => entry.$2.followRedirects), [false, false]);
  });
}
