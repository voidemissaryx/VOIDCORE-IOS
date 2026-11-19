import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ech_client.dart';
import 'my_ip.dart';
import 'vpn_channel.dart';

typedef CloudflareRoute = Future<http.Client?> Function();

/// The HTTP client of every Cloudflare API call (api.cloudflare.com, WARP and MASQUE
/// registration): [CloudflareApi], [WarpRegistrar] and [MasqueRegistrar] use it by default, so
/// callers never choose a route. Each request goes
///
///  1. directly;
///  2. through the running tunnel, when connected;
///  3. through the local ECH gateway (networking/).
///
/// A route is tried only after the one before failed to reach the server (blocked, timed out,
/// reset); a response of any status, even an error, ends it. A failure after the request was
/// sent retries too, so a write the server already applied may be applied twice. When every
/// route fails, the first error (the direct one) is thrown.
///
/// [viaTor] (the setup wizard's Tor retry) replaces all of that with Tor alone.
class CloudflareClient extends http.BaseClient {
  /// The tunnel's local proxy port while connected, else null; set by [AppState].
  static int? Function()? tunnelPort;

  static final _torKey = Object();

  /// Runs [body] with every Cloudflare request made in it going through the HTTP proxy on
  /// [port] only (Tor): no direct, tunnel or ECH route.
  static Future<T> viaTor<T>(int port, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_torKey: port});

  static Future<void>? _gateway;

  static Future<void> _startGateway() => _gateway ??= () async {
    try {
      await VpnChannel.startEchGateway();
    } catch (_) {
      _gateway = null;
      rethrow;
    }
  }();

  /// The routes are [routes] for tests, else the three above.
  CloudflareClient({this.routes});

  final List<CloudflareRoute>? routes;
  final _owned = <http.Client>[];
  http.Client? _direct, _tunnel, _ech, _tor;

  http.Client _own(http.Client client) {
    _owned.add(client);
    return client;
  }

  late final List<CloudflareRoute> _defaultRoutes = [
    () async => _direct ??= _own(
      proxiedClient(null, connectTimeout: const Duration(seconds: 8)),
    ),
    () async {
      final port = tunnelPort?.call();
      return port == null ? null : _tunnel ??= _own(proxiedClient(port));
    },
    () async {
      await _startGateway();
      return _ech ??= _own(
        EchClient(
          dial: {
            'api.cloudflareclient.com': '188.114.96.0:443', // WARP and MASQUE
            'api.cloudflare.com': '188.114.97.0:443',
          },
        ),
      );
    },
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // A request can be sent once; keep its body to send copies.
    final body = await request.finalize().toBytes();
    http.Request copy() => http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = body
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;

    final tor = Zone.current[_torKey] as int?;
    final chain = tor != null
        ? <CloudflareRoute>[() async => _tor ??= _own(proxiedClient(tor))]
        : (routes ?? _defaultRoutes);

    Object? first;
    StackTrace? firstStack;
    for (final route in chain) {
      try {
        final client = await route();
        if (client == null) continue;
        return await client.send(copy());
      } catch (e, st) {
        if (first == null) {
          if (!_isTransportError(e)) rethrow;
          first = e;
          firstStack = st;
        }
      }
    }
    Error.throwWithStackTrace(first!, firstStack!);
  }

  /// The server couldn't be reached (blocked, timed out, reset), rather than answering.
  static bool _isTransportError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HandshakeException ||
      e is TlsException ||
      e is HttpException ||
      e is http.ClientException;

  @override
  void close() {
    for (final client in _owned) {
      client.close();
    }
  }
}
