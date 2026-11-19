import 'package:http/http.dart' as http;

/// Sends requests to the local ECH gateway (networking/), which forwards them to the real host
/// over TLS with Encrypted Client Hello. Only the hosts the gateway allows work.
class EchClient extends http.BaseClient {
  EchClient({
    String gateway = 'http://127.0.0.1:10810',
    this.dial = const {},
    http.Client? inner,
  })  : _gw = Uri.parse(gateway),
        _inner = inner ?? http.Client();

  final Uri _gw;
  final http.Client _inner;

  /// Optional per-host IP pinning: {'api.example.com': '104.16.1.1:443'}
  final Map<String, String> dial;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final u = request.url;
    final out = http.StreamedRequest(
      request.method,
      Uri(
        scheme: _gw.scheme,
        host: _gw.host,
        port: _gw.port,
        path: u.path.isEmpty ? '/' : u.path,
        query: u.hasQuery ? u.query : null,
      ),
    )
      ..followRedirects = false // a followed Location would bypass the gateway
      ..persistentConnection = request.persistentConnection
      ..contentLength = request.contentLength
      ..headers.addAll(request.headers)
      ..headers['X-SNI'] = u.host;

    final pinned = dial[u.host];
    if (pinned != null) {
      out.headers['X-Dial'] = pinned;
    } else if (u.hasPort && u.port != 443) {
      out.headers['X-Dial'] = '${u.host}:${u.port}';
    }
    if (u.hasPort) out.headers['X-Host'] = u.authority;

    request.finalize().listen(
          out.sink.add,
          onError: out.sink.addError,
          onDone: out.sink.close,
          cancelOnError: true,
        );
    return _inner.send(out).then(_checkGateway);
  }

  /// The gateway answers with this header when it couldn't reach the host: that's a network
  /// failure, not the host's own response.
  Future<http.StreamedResponse> _checkGateway(http.StreamedResponse response) async {
    if (response.headers['x-ech-error'] == null) return response;
    final reason = await response.stream.bytesToString();
    throw http.ClientException('ECH gateway: $reason', response.request?.url);
  }

  @override
  void close() => _inner.close();
}
