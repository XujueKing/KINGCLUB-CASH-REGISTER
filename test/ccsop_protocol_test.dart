import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/network/ccsop_crypto.dart';
import 'package:kingclub_cash_register/src/network/ccsop_realtime_codec.dart';

Future<Map<String, dynamic>> peer(String mode, [Object? input]) async {
  final process = await Process.start('node', [
    'test/support/ccsop_peer.mjs',
    mode,
  ]);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  if (input != null) process.stdin.write(jsonEncode(input));
  await process.stdin.close();
  expect(await process.exitCode, 0, reason: await stderr);
  return jsonObject(jsonDecode(await stdout));
}

class FakeTransport implements JsonTransport {
  final pending = Completer<JsonReply>();
  final requested = Completer<void>();
  int calls = 0;
  Uri? uri;
  @override
  Future<JsonReply> post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) {
    calls++;
    this.uri = uri;
    requested.complete();
    return pending.future;
  }

  @override
  void close() {}
}

void main() {
  late Map<String, dynamic> fixture;
  late CcsopCredentials credentials;
  late RequestStamp stamp;
  setUpAll(() async {
    fixture = await peer('fixtures');
    final c = jsonObject(fixture['credentials']);
    final s = jsonObject(fixture['stamp']);
    credentials = CcsopCredentials(
      apiKeyId: c['apiKeyId'],
      sessionId: c['sessionId'],
      apiKey: c['apiKey'],
    );
    stamp = RequestStamp(
      timestamp: s['timestamp'],
      nonce: s['nonce'],
      requestId: s['requestId'],
    );
  });

  test('HTTPS only, no credentials/query/fragment; preserves proxy prefix', () {
    expect(
      serviceBase('https://service.invalid/kingclub-v2///').path,
      '/kingclub-v2',
    );
    for (final url in [
      'http://service.invalid',
      'https://u:p@service.invalid',
      'https://service.invalid?token=x',
      'https://service.invalid#fragment',
      'invalid',
    ]) {
      expect(() => serviceBase(url), throwsArgumentError);
    }
  });

  test(
    'Dart signed encrypted request is independently decrypted by Node',
    () async {
      final request = await sealRequest(
        credentials: credentials,
        interfaceId: 'K260920000820',
        params: {'name': '测试专用'},
        stamp: stamp,
      );
      expect(jsonEncode(request.body), isNot(contains('测试专用')));
      final decoded = await peer('request', {
        'headers': request.headers,
        'body': request.body,
      });
      expect(decoded, {
        'interfaceId': 'K260920000820',
        'params': {'name': '测试专用'},
      });
    },
  );

  test(
    'Node response decrypts; plain/tampered/cross-request data rejected',
    () async {
      final request = await sealRequest(
        credentials: credentials,
        interfaceId: 'K260920000820',
        params: {},
        stamp: stamp,
      );
      final response = jsonObject(fixture['response']);
      expect(await request.openResponse(response), {
        'result': {'count': 3, 'name': '测试专用'},
      });
      await expectLater(
        request.openResponse({
          'status': 1,
          'code': 'success',
          'data': {'result': 'plain'},
        }),
        throwsA(anything),
      );
      await expectLater(
        request.openResponse({...response, 'status': 0}),
        throwsFormatException,
      );
      final data = jsonObject(response['data']);
      await expectLater(
        request.openResponse({
          ...response,
          'data': {...data, 'tag': b64(List.filled(16, 0))},
        }),
        throwsA(anything),
      );
      final other = await sealRequest(
        credentials: credentials,
        interfaceId: 'K260920000820',
        params: {},
      );
      await expectLater(other.openResponse(response), throwsA(anything));
    },
  );

  test('Cashier path and signed store match independent Node crypto', () async {
    final codec = CcsopRealtimeCodec(
      credentials,
      'store:test-store',
      stamp: stamp,
      endpoint: '/cashier/ws',
    );
    final uri = await codec.connectionUri('https://service.invalid/prefix');
    expect(uri.path, '/prefix/cashier/ws');
    expect(uri.queryParameters['sign'], fixture['cashierWsSign']);
    codec.close();
  });
  test('WS handshake signature and encrypted outbound match Node', () async {
    final codec = CcsopRealtimeCodec(
      credentials,
      fixture['clientId'],
      stamp: stamp,
    );
    final uri = await codec.connectionUri(
      'https://service.invalid/kingclub-v2',
    );
    expect(uri.scheme, 'wss');
    expect(uri.path, '/kingclub-v2/ws');
    expect(uri.queryParameters['sign'], fixture['wsSign']);
    expect(
      await peer(
        'outbound',
        jsonDecode(await codec.encode('client.foreground', {'active': true})),
      ),
      {'active': true},
    );
    codec.close();
    await expectLater(
      codec.connectionUri('https://service.invalid'),
      throwsStateError,
    );
  });

  test(
    'WS replay, concurrent duplicate, tampering and plaintext rejected',
    () async {
      final codec = CcsopRealtimeCodec(
        credentials,
        fixture['clientId'],
        stamp: stamp,
      );
      final first = jsonEncode(fixture['frames'][0]);
      final second = jsonEncode(fixture['frames'][1]);
      final attempts = [codec.decode(first), codec.decode(first)];
      final rejected = expectLater(attempts[1], throwsFormatException);
      expect((await attempts[0])['data'], {'revision': 1});
      await rejected;
      await expectLater(
        codec.decode(
          jsonEncode({
            ...jsonObject(fixture['frames'][1]),
            'eventType': 'tampered',
          }),
        ),
        throwsFormatException,
      );
      // Failed signature must not consume the sequence or poison the queue.
      expect((await codec.decode(second))['data'], {'revision': 2});
      await expectLater(codec.decode(first), throwsFormatException);
      await expectLater(
        codec.decode('{"encrypted":false,"seq":3}'),
        throwsFormatException,
      );
      codec.close();
      await expectLater(codec.decode(second), throwsStateError);
    },
  );

  test('concurrent outbound operations preserve emission sequence', () async {
    final codec = CcsopRealtimeCodec(
      credentials,
      fixture['clientId'],
      stamp: stamp,
    );
    final frames = await Future.wait(
      List.generate(12, (i) => codec.encode('test', {'i': i})),
    );
    expect(
      frames.map((v) => jsonObject(jsonDecode(v))['seq']),
      List.generate(12, (i) => i + 1),
    );
  });

  test(
    'HTTP never retries on failure, preserves prefix and sanitizes error',
    () async {
      final transport = FakeTransport();
      final client = CcsopClient(
        'https://service.invalid/proxy',
        credentials,
        transport: transport,
      );
      final pending = client.call('K260920000820', {});
      final rejected = expectLater(
        pending,
        throwsA(
          isA<CcsopFailure>()
              .having((v) => v.code, 'code', 'SERVICE_REJECTED')
              .having((v) => v.deliveryUncertain, 'uncertain', true),
        ),
      );
      await transport.requested.future;
      transport.pending.complete(
        const JsonReply(500, {
          'code': 'secret with spaces',
          'message': 'sensitive data',
        }),
      );
      await rejected;
      expect(transport.calls, 1);
      expect(transport.uri!.path, '/proxy/supper-interface');
      client.close();
      await expectLater(
        client.call('K260920000820', {}),
        throwsA(isA<CcsopFailure>()),
      );
      expect(transport.calls, 1);
    },
  );

  test('late HTTP response cannot revive a closed employee session', () async {
    final transport = FakeTransport();
    final client = CcsopClient(
      'https://service.invalid',
      credentials,
      transport: transport,
    );
    final pending = client.call('K260920000820', {});
    final rejected = expectLater(
      pending,
      throwsA(
        isA<CcsopFailure>().having((v) => v.code, 'code', 'SESSION_CHANGED'),
      ),
    );
    await transport.requested.future;
    client.close();
    transport.pending.complete(JsonReply(200, jsonObject(fixture['response'])));
    await rejected;
  });
}
