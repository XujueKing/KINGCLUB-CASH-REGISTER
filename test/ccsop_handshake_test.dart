import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/network/ccsop_crypto.dart';
import 'package:kingclub_cash_register/src/network/ccsop_handshake.dart';

Future<Map<String, dynamic>> node(String mode, Object input) async {
  final process = await Process.start('node', [
    'test/support/ccsop_peer.mjs',
    mode,
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(jsonEncode(input));
  await process.stdin.close();
  expect(await process.exitCode, 0, reason: await errors);
  return jsonObject(jsonDecode(await output));
}

class PeerTransport implements JsonTransport {
  String? sessionKey;
  final paths = <String>[];
  Map<String, dynamic>? received;
  bool invalidAlgorithm = false, tamper = false, closed = false;
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  Future<JsonReply> post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async {
    paths.add(uri.path);
    if (uri.path.endsWith('/supper-handshake')) {
      if (!started.isCompleted) started.complete();
      if (gate != null) await gate!.future;
      final result = await node('handshake', body);
      sessionKey = result['sessionKey'] as String;
      final reply = jsonObject(result['reply']);
      if (invalidAlgorithm) {
        jsonObject(jsonObject(reply['data'])['alg'])['kdf'] = 'unsafe';
      }
      return JsonReply(200, reply);
    }
    expect(jsonEncode(body), isNot(contains('TEST-ONLY-PASSWORD')));
    final result = await node('handshake-request', {
      'sessionKey': sessionKey,
      'headers': headers,
      'body': body,
    });
    received = jsonObject(result['request']);
    final reply = jsonObject(result['reply']);
    if (tamper) jsonObject(reply['data'])['tag'] = b64(List.filled(16, 0));
    return JsonReply(200, reply);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
    'P256 ECDH shared secret matches independent Node implementation',
    () async {
      for (var i = 0; i < 3; i++) {
        final pair = await EphemeralP256.create();
        try {
          final server = await node('handshake', {
            'clientPublicKey': pair.publicKey,
            'clientNonce': 'test-only-nonce',
          });
          final public =
              jsonObject(jsonObject(server['reply'])['data'])['serverPublicKey']
                  as String;
          expect(
            b64(await (await pair.agree(public)).extractBytes()),
            server['shared'],
          );
        } finally {
          pair.close();
        }
      }
    },
  );
  test(
    'rejects infinity, off-curve and out-of-field points, and closed key',
    () async {
      final pair = await EphemeralP256.create();
      for (final bytes in [
        [0],
        [4, ...List.filled(64, 0)],
        [4, ...List.filled(64, 255)],
      ]) {
        await expectLater(pair.agree(b64(bytes)), throwsFormatException);
      }
      pair.close();
      await expectLater(
        pair.agree(pair.publicKey),
        throwsA(isA<CcsopFailure>()),
      );
    },
  );
  test('login and refresh use fresh handshake, preserve path and never transmit plaintext password', () async {
    final peer = PeerTransport();
    final client = CcsopHandshakeClient(
      'https://service.invalid/kingclub-v2',
      transport: peer,
    );
    for (final id in ['K260929001901', 'K260929001903']) {
      final result = await client.call(id, {'password': 'TEST-ONLY-PASSWORD'});
      expect(result, {'apiKey': 'TEST-ONLY-ISSUED-KEY', 'interfaceId': id});
      expect(peer.received, {
        'interfaceId': id,
        'params': {'password': 'TEST-ONLY-PASSWORD'},
      });
    }
    expect(peer.paths, [
      '/kingclub-v2/supper-handshake',
      '/kingclub-v2/supper-interface',
      '/kingclub-v2/supper-handshake',
      '/kingclub-v2/supper-interface',
    ]);
    client.close();
    expect(peer.closed, isTrue);
  });
  test(
    'rejects changed algorithms before submitting login credentials',
    () async {
      final peer = PeerTransport()..invalidAlgorithm = true;
      final client = CcsopHandshakeClient(
        'https://service.invalid',
        transport: peer,
      );
      await expectLater(
        client.call('K260929001901', {}),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.deliveryUncertain,
            'not submitted',
            false,
          ),
        ),
      );
      expect(peer.paths, ['/supper-handshake']);
      client.close();
    },
  );
  test('tampered response never becomes an authenticated session and is not retried', () async {
    final peer = PeerTransport()..tamper = true;
    final client = CcsopHandshakeClient(
      'https://service.invalid',
      transport: peer,
    );
    await expectLater(
      client.call('K260929001901', {}),
      throwsA(
        isA<CcsopFailure>().having(
          (e) => e.deliveryUncertain,
          'submitted',
          true,
        ),
      ),
    );
    expect(peer.paths.length, 2);
    client.close();
  });
  test(
    'serializes authentication and discards late handshake after close',
    () async {
      final peer = PeerTransport()..gate = Completer<void>();
      final client = CcsopHandshakeClient(
        'https://service.invalid',
        transport: peer,
      );
      final pending = client.call('K260929001901', {});
      await peer.started.future;
      await expectLater(
        client.call('K260929001903', {}),
        throwsA(
          isA<CcsopFailure>().having((e) => e.code, 'busy', 'AUTH_IN_PROGRESS'),
        ),
      );
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      client.close();
      peer.gate!.complete();
      await rejected;
      expect(peer.paths.length, 1);
    },
  );
  test('rejects non-auth interfaces before networking', () async {
    final peer = PeerTransport();
    final client = CcsopHandshakeClient(
      'https://service.invalid',
      transport: peer,
    );
    await expectLater(
      client.call('K260929001902', {}),
      throwsA(isA<CcsopFailure>()),
    );
    expect(peer.paths, isEmpty);
    client.close();
  });
}
