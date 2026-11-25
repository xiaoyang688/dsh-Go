import 'package:dsh_app/remote/https_launch_url.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';

const _url = 'https://example.com:8443/dsh/?token=test%2Bcredential';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts an HTTPS authorization URL, preserving prefix, port and token', () {
    final uri = parseRemoteHttpsLaunchUrl(' $_url\n')!;
    expect(uri.path, '/dsh/');
    expect(uri.port, 8443);
    expect(uri.queryParameters, {'token': 'test+credential'});
  });

  test('rejects insecure, ambiguous and incomplete authorization URLs', () {
    for (final raw in [
      'http://example.com/dsh/?token=test',
      'https://example.com/dsh/',
      '//example.com/dsh/?token=test',
      'https:///dsh/?token=test',
      'https://someone:secret@example.com/?token=test',
      'https://@example.com/?token=test',
      'https://example.com/?token=test#',
      'https://example.com/?token=test#fragment',
      'https://example.com/?token=a&token=b',
      'https://example.com/?token=a&forward=b',
      'https://example.com/?token=',
      'https://example.com/?token=%20',
      'https://example.com/?token=%00',
      'https://example.com/?token=%XX',
      'https://example.com/?token=%FF',
      'https://example.com:99999/?token=test',
      'https://example.com/with space/?token=test',
      r'https://example.com\other/?token=test',
    ]) {
      expect(parseRemoteHttpsLaunchUrl(raw), isNull, reason: raw);
    }
  });

  test('only secure storage persists the URL and only its exact owner can read or remove it', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = MemorySecretStore();
    final backend = FakeRelayBackend(
      user: sampleRelayUser,
      hosts: [
        ...sampleRelayHosts,
        const RelayHost(id: 'second', name: 'Second', online: true),
      ],
    );
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [secretStoreProvider.overrideWithValue(secrets), relayBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(c.dispose);
      return c;
    }

    final c = open();
    final line = remoteHttpsLaunchUrlProvider('mac');
    final sub = c.listen(line, (_, _) {});
    addTearDown(sub.close);
    expect(await c.read(line.future), isNull);
    final owner = c.read(remoteHttpsScopeProvider)!;
    final settings = c.read(remoteHttpsSettingsProvider);
    await expectLater(
      settings.save(owner, 'mac', 'https://example.com/'),
      throwsA(isA<RemoteHttpsSettingsException>()),
    );
    expect(secrets.values, isEmpty);
    await settings.save(owner, 'mac', _url);
    expect(await c.read(line.future), Uri.parse(_url));
    expect(secrets.values.values, [_url]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
    expect(await c.read(remoteHttpsLaunchUrlProvider('second').future), isNull);

    final restored = open();
    final restoredLine = restored.listen(line, (_, _) {});
    addTearDown(restoredLine.close);
    expect(await restored.read(line.future), Uri.parse(_url));
    await c.read(relayServerProvider.notifier).useServer('https://second.example');
    expect(await c.read(line.future), isNull);
    await expectLater(settings.save(owner, 'mac', null), throwsA(isA<RemoteHttpsSettingsException>()));
    expect(secrets.values.values, [_url]);
    await c.read(relayServerProvider.notifier).useDefault();
    expect(await c.read(line.future), Uri.parse(_url));

    await c.read(relayAccountProvider.notifier).logout();
    expect(await c.read(line.future), isNull);
    backend.user = const RelayUser(id: 'another', displayName: 'Another');
    c.invalidate(relayAccountProvider);
    expect(await c.read(line.future), isNull);
    backend.user = sampleRelayUser;
    c.invalidate(relayAccountProvider);
    expect(await c.read(line.future), Uri.parse(_url));
    await settings.save(owner, 'mac', null);
    expect(await c.read(line.future), isNull);
    expect(secrets.values, isEmpty);
  });
}
