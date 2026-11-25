import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../https_launch_url.dart';
import '../link_status.dart';
import 'relay_backend.dart';

/// A configured HTTPS route gets one bounded chance to become ready before
/// opening the Remote tunnel. After publication, only that route can recover:
/// a dropped connection never sends an outstanding operation over the tunnel.
class HttpsFirstHostLink implements HostLink, NetworkInspectableHostLink {
  HttpsFirstHostLink({
    required this.fallback,
    required this._launchUrl,
    Stream<void>? kicks,
    this._timeout = const Duration(seconds: 5),
  }) {
    // Handle secure storage failure even when a status row creates this link
    // before anything asks it to open.
    _launchUrl.ignore();
    _fallbackStatuses = fallback.statuses.listen(_followFallback);
    _fallbackClients = fallback.clients.listen(_clients.add);
    _kicks = kicks?.listen((_) => kick());
  }

  final RelayHostLink fallback;
  final Future<Uri?> _launchUrl;
  final Duration _timeout;
  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  late final StreamSubscription<HostLinkStatus> _fallbackStatuses;
  late final StreamSubscription<DshClient> _fallbackClients;
  StreamSubscription<void>? _kicks;
  StreamSubscription<DshConnectionState>? _muxStates;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _direct;
  Future<DshClient>? _opening;
  bool _usingFallback = false;
  bool _httpsFailed = false;
  bool _published = false;
  bool _closed = false;

  @override
  HostLinkStatus get status => _status;
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  @override
  Stream<DshClient> get clients => _clients.stream;
  @override
  DshClient? get currentClient => _usingFallback
      ? fallback.currentClient
      : _published && _direct?.mux.generation != null
      ? _direct
      : null;

  void _emit(HostLinkStatus status) {
    if (_closed) return;
    _status = status;
    _statuses.add(status);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(const DshClosedException('Host link closed'));
    if (_usingFallback) return fallback.open();
    if (currentClient case final client?) return Future.value(client);
    if (_published) return _waitForDirect();
    return _opening ??= _openInitial().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openInitial() async {
    try {
      final url = await _launchUrl.timeout(_timeout);
      if (!_closed && url != null) {
        _httpsFailed = true;
        if (parseRemoteHttpsLaunchUrl(url.toString()) == null) {
          throw const DshProtocolException('Invalid configured HTTPS launch URL');
        }
        final launch = DshLaunchUrl.tryParse(url.toString())!;
        _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.login));
        final connection = DshConnection(launch.baseUri, strictHttps: true, connectTimeout: _timeout);
        final client = _direct = DshClient(connection);
        Future<void> prepare() async {
          await connection.login(launch.token);
          await client.mux.ready();
        }

        await prepare().timeout(_timeout);
        if (!_closed && client.mux.generation != null) {
          _published = true;
          _muxStates = client.mux.states.listen((_) => _followDirect(client));
          _followDirect(client);
          return client;
        }
      }
    } on Object {
      // Attempt failures can include credentials in HTTP responses. Do not
      // publish the raw error, URI, or cookie through the HostLink.
    }
    await _closeDirect();
    if (_closed) throw const DshClosedException('Host link closed');
    _usingFallback = true;
    return fallback.open();
  }

  void _followFallback(HostLinkStatus status) {
    final network = status.network;
    _emit(
      _httpsFailed
          ? status.withNetwork(
              RemoteNetworkStatus(
                path: status.path,
                connectDuration: network?.connectDuration,
                roundTripTime: network?.roundTripTime,
                observedAt: network?.observedAt,
                localIpVersion: network?.localIpVersion,
                remoteIpVersion: network?.remoteIpVersion,
                iceProtocol: network?.iceProtocol,
                fallbackReason: 'httpsUnavailable',
              ),
            )
          : status,
    );
  }

  void _followDirect(DshClient client) {
    // Sample state instead of replaying queued transitions from an old socket.
    switch (client.mux.state) {
      case DshConnectionState.connected:
        _emit(
          const HostLinkStatus(
            HostLinkPhase.connected,
            completed: {HostLinkStep.connect, HostLinkStep.login},
            path: RelayPath.https,
          ),
        );
      case DshConnectionState.unauthorized:
        _emit(HostLinkStatus(HostLinkPhase.failed, path: RelayPath.https, error: _directFailure(auth: true)));
      case DshConnectionState.closed:
        _emit(HostLinkStatus(HostLinkPhase.failed, path: RelayPath.https, error: _directFailure()));
      case DshConnectionState.idle || DshConnectionState.connecting || DshConnectionState.reconnecting:
        _emit(const HostLinkStatus(HostLinkPhase.reconnecting, path: RelayPath.https));
    }
  }

  HostLinkError _directFailure({bool auth = false}) => HostLinkError(
    auth ? HostLinkErrorKind.loginFailed : HostLinkErrorKind.unreachable,
    auth ? appL10n.remoteErrDshSignInExpired : appL10n.remoteErrHostUnreachable,
    diagnosticCode: auth ? HostLinkDiagnosticCode.httpsUnauthorized : HostLinkDiagnosticCode.httpsUnavailable,
  );

  Future<DshClient> _waitForDirect() async {
    final client = _direct!;
    try {
      await client.mux.ready(timeout: _timeout);
      if (!_closed && client.mux.generation != null) return client;
    } on Object {
      if (!_closed) throw _directFailure(auth: client.mux.state == DshConnectionState.unauthorized);
    }
    throw const DshClosedException('Host link closed');
  }

  @override
  void kick() {
    if (_usingFallback) {
      fallback.kick();
    } else if (_published && _status.phase == HostLinkPhase.reconnecting) {
      _direct?.mux.reconnect();
    }
  }

  @override
  void retry() {
    if (_usingFallback) {
      fallback.retry();
    } else if (_published) {
      _direct?.mux.reconnect();
    } else {
      open().ignore();
    }
  }

  @override
  Future<RemoteNetworkStatus?> inspectNetwork() => _usingFallback ? fallback.inspectNetwork() : Future.value(null);

  Future<void> _closeDirect() async {
    final client = _direct;
    _direct = null;
    if (client == null) return;
    client.connection.close(force: true);
    await client.close().catchError((Object _) {});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([
      _closeDirect(),
      _kicks?.cancel() ?? Future.value(),
      _muxStates?.cancel() ?? Future.value(),
      _fallbackStatuses.cancel(),
      _fallbackClients.cancel(),
    ]);
    await fallback.close();
    unawaited(_statuses.close());
    unawaited(_clients.close());
  }
}
