import 'dart:io';

import 'package:bpb/services/cloudflare_client.dart';
import 'package:bpb/services/ech_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final url = Uri.parse('https://api.cloudflare.com/client/v4/accounts');

  test('a failed route falls to the next, which gets the same request body', () async {
    String? body;
    String? auth;
    final client = CloudflareClient(routes: [
      () async => MockClient((_) async => throw const SocketException('unreachable')),
      () async => null, // e.g. the tunnel, when not connected
      () async => MockClient((r) async {
            body = r.body;
            auth = r.headers['Authorization'];
            return http.Response('ok', 200);
          }),
    ]);
    final res = await client.post(url, headers: {'Authorization': 'Bearer t'}, body: '{"a":1}');
    expect(res.statusCode, 200);
    expect(auth, 'Bearer t');
    expect(body, '{"a":1}');
  });

  test('an HTTP error status is an answer: no further route', () async {
    var next = false;
    final client = CloudflareClient(routes: [
      () async => MockClient((_) async => http.Response('nope', 403)),
      () async {
        next = true;
        return MockClient((_) async => http.Response('', 200));
      },
    ]);
    expect((await client.get(url)).statusCode, 403);
    expect(next, isFalse);
  });

  test('when every route fails, the first error is thrown', () async {
    final client = CloudflareClient(routes: [
      () async => MockClient((_) async => throw const SocketException('direct')),
      () async => MockClient((_) async => throw http.ClientException('gateway')),
    ]);
    await expectLater(client.get(url), throwsA(isA<SocketException>()));
  });

  test('an error that is not a network failure is not retried', () async {
    var next = false;
    final client = CloudflareClient(routes: [
      () async => MockClient((_) async => throw StateError('bug')),
      () async {
        next = true;
        return MockClient((_) async => http.Response('', 200));
      },
    ]);
    await expectLater(client.get(url), throwsStateError);
    expect(next, isFalse);
  });

  test('a route that cannot start (no gateway) leaves the first error', () async {
    final client = CloudflareClient(routes: [
      () async => MockClient((_) async => throw const SocketException('direct')),
      () async => throw StateError('no plugin'),
    ]);
    await expectLater(client.get(url), throwsA(isA<SocketException>()));
  });

  test('viaTor uses Tor alone', () async {
    var hit = false;
    final client = CloudflareClient(routes: [
      () async {
        hit = true;
        return MockClient((_) async => http.Response('', 200));
      },
    ]);
    // Nothing listens on this port: only the Tor route is tried, and its failure surfaces.
    await expectLater(
      CloudflareClient.viaTor(1, () => client.get(url)),
      throwsA(isA<Exception>()),
    );
    expect(hit, isFalse);
  });

  test('EchClient sends the real host in X-SNI and fails on a gateway error', () async {
    late http.BaseRequest seen;
    final ok = EchClient(inner: MockClient((r) async {
      seen = r;
      return http.Response('{}', 200);
    }));
    await ok.get(url.replace(query: 'x=1'));
    expect(seen.url.toString(), 'http://127.0.0.1:10810/client/v4/accounts?x=1');
    expect(seen.headers['X-SNI'], 'api.cloudflare.com');

    final down = EchClient(inner: MockClient((_) async => http.Response('dial failed', 502, headers: {'x-ech-error': '1'})));
    await expectLater(down.get(url), throwsA(isA<http.ClientException>()));
  });
}
