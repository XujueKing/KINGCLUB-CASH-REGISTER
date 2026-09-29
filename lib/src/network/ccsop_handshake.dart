import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:pointycastle/export.dart' as pc;
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;

import 'ccsop_client.dart';
import 'ccsop_crypto.dart';

BigInt _integer(List<int> bytes) => BigInt.parse(
  bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  radix: 16,
);
Uint8List _fixed32(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  if (hex.length != 64) throw const FormatException('Invalid P256 value');
  return Uint8List.fromList(
    List.generate(
      32,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ),
  );
}

/// Short-lived key agreement. CPU-heavy EC work is off the Flutter UI isolate.
class EphemeralP256 {
  EphemeralP256._(this._private, this.publicKey);
  BigInt? _private;
  final String publicKey;

  static Future<EphemeralP256> create() => Isolate.run(() {
    final random = Random.secure();
    final seed = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final secure = pc.FortunaRandom()..seed(pc.KeyParameter(seed));
    seed.fillRange(0, seed.length, 0);
    final generator = pc.ECKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(pc.ECDomainParameters('prime256v1')),
          secure,
        ),
      );
    final pair = generator.generateKeyPair();
    return EphemeralP256._(
      pair.privateKey.d!,
      b64(pair.publicKey.Q!.getEncoded(false)),
    );
  });

  Future<SecretKey> agree(String serverPublicKey) async {
    final private = _private;
    if (private == null) throw const CcsopFailure('HANDSHAKE_CLOSED');
    final bytes = unb64(serverPublicKey);
    if (bytes.length != 65 || bytes.first != 4) {
      throw const FormatException('Invalid P256 public key');
    }
    final shared = await Isolate.run(() {
      final domain = pc.ECDomainParameters('prime256v1');
      final curve = domain.curve as fp.ECCurve;
      final x = _integer(bytes.sublist(1, 33)), y = _integer(bytes.sublist(33));
      final q = curve.q!;
      // PointyCastle uncompressed decoding alone does not validate curve membership.
      if (x >= q ||
          y >= q ||
          (y * y -
                      x * x * x -
                      curve.a!.toBigInteger()! * x -
                      curve.b!.toBigInteger()!) %
                  q !=
              BigInt.zero) {
        throw const FormatException('Invalid P256 point');
      }
      final agreement = pc.ECDHBasicAgreement()
        ..init(pc.ECPrivateKey(private, domain));
      return _fixed32(
        agreement.calculateAgreement(
          pc.ECPublicKey(domain.curve.decodePoint(bytes), domain),
        ),
      );
    });
    if (_private == null) throw const CcsopFailure('HANDSHAKE_CLOSED');
    return SecretKey(shared);
  }

  void close() {
    _private = null;
  } // Drop reference; managed memory is not guaranteed zeroized.
}

Future<SealedRequest> sealHandshakeRequest({
  required String handshakeId,
  required SecretKey sessionKey,
  required String interfaceId,
  required Map<String, dynamic> params,
  RequestStamp? stamp,
}) async {
  if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(handshakeId) ||
      !{'K260929001901', 'K260929001903'}.contains(interfaceId)) {
    throw ArgumentError('Invalid cashier handshake scope');
  }
  final s = stamp ?? RequestStamp();
  Future<SecretKey> key(String purpose) => derive(
    sessionKey,
    s.salt,
    'ccsop:supper-interface:$purpose:${s.requestId}',
  );
  final data = await encrypt(await key('request'), {
    'interfaceId': interfaceId,
    'params': params,
  });
  final canonical = [
    'POST',
    '/supper-interface',
    handshakeId,
    '',
    s.timestamp,
    s.nonce,
    s.requestId,
    await sha256Hex(jsonEncode(data)),
  ].join('\n');
  return SealedRequest(
    Map.unmodifiable({
      'x-handshake-id': handshakeId,
      'x-timestamp': s.timestamp,
      'x-nonce': s.nonce,
      'x-request-id': s.requestId,
    }),
    {'data': data, 'sign': await sign(await key('sign'), canonical)},
    await key('response'),
  );
}

/// One serialized login/refresh operation, with fresh ECDH each time. No retries or persistence.
abstract interface class AuthChannel {
  Future<Map<String, dynamic>> call(
    String interfaceId,
    Map<String, dynamic> params,
  );
  void close();
}

class CcsopHandshakeClient implements AuthChannel {
  CcsopHandshakeClient(String base, {JsonTransport? transport})
    : base = serviceBase(base),
      _transport = transport ?? IoJsonTransport();
  final Uri base;
  final JsonTransport _transport;
  bool _closed = false, _busy = false;

  @override
  Future<Map<String, dynamic>> call(
    String interfaceId,
    Map<String, dynamic> params,
  ) async {
    if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
    if (_busy) throw const CcsopFailure('AUTH_IN_PROGRESS');
    if (!{'K260929001901', 'K260929001903'}.contains(interfaceId)) {
      throw const CcsopFailure('AUTH_SCOPE_INVALID');
    }
    _busy = true;
    EphemeralP256? ephemeral;
    var submitted = false;
    try {
      ephemeral = await EphemeralP256.create();
      if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
      final nonce = RequestStamp().nonce;
      final elapsed = Stopwatch()..start();
      final reply = await _transport.post(
        base.replace(path: '${base.path}/supper-handshake'),
        {},
        {
          'clientPublicKey': ephemeral.publicKey,
          'clientNonce': nonce,
          'clientType': 'device',
          'clientVersion': 'cashier-v1',
        },
      );
      _checkReply(reply, false);
      final data = jsonObject(reply.body['data']);
      final alg = jsonObject(data['alg']);
      if (alg['keyAgreement'] != 'ECDH-P256' ||
          alg['payload'] != 'AES-256-GCM' ||
          alg['kdf'] != 'HKDF-SHA256' ||
          alg['sign'] != 'HMAC-SHA256') {
        throw const FormatException('Unsupported algorithms');
      }
      final ttl = data['expiresIn'];
      if (ttl is! int || ttl < 1 || ttl > 3600) {
        throw const FormatException('Invalid handshake expiry');
      }
      final handshakeId = data['handshakeId'] as String;
      final sessionKey = await derive(
        await ephemeral.agree(data['serverPublicKey'] as String),
        nonce,
        'ccsop:supper-handshake:$handshakeId',
      );
      ephemeral.close();
      final sealed = await sealHandshakeRequest(
        handshakeId: handshakeId,
        sessionKey: sessionKey,
        interfaceId: interfaceId,
        params: params,
      );
      if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
      if (elapsed.elapsedMilliseconds >= ttl * 1000) {
        throw const CcsopFailure('HANDSHAKE_EXPIRED');
      }
      submitted = true;
      final response = await _transport.post(
        base.replace(path: '${base.path}/supper-interface'),
        sealed.headers,
        sealed.body,
      );
      _checkReply(response, true);
      final value = jsonObject(await sealed.openResponse(response.body));
      if (_closed) {
        throw const CcsopFailure('SESSION_CHANGED', deliveryUncertain: true);
      }
      return jsonObject(value['result']);
    } on CcsopFailure {
      rethrow;
    } catch (_) {
      throw CcsopFailure('INVALID_AUTH_RESPONSE', deliveryUncertain: submitted);
    } finally {
      ephemeral?.close();
      _busy = false;
    }
  }

  void _checkReply(JsonReply reply, bool submitted) {
    if (_closed) {
      throw CcsopFailure('SESSION_CHANGED', deliveryUncertain: submitted);
    }
    if (reply.statusCode != 200 ||
        reply.body['status'] != 1 ||
        reply.body['code'] != 'success') {
      final code = reply.body['code'];
      throw CcsopFailure(
        code is String && RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code)
            ? code
            : 'AUTH_REJECTED',
        deliveryUncertain: submitted,
      );
    }
  }

  @override
  void close() {
    _closed = true;
    _transport.close();
  }
}
