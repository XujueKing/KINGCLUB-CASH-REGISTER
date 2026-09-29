import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Wire compatibility with ccsop-service. No credentials are persisted here.
class CcsopCredentials {
  CcsopCredentials({
    required this.apiKeyId,
    required this.sessionId,
    required String apiKey,
  }) : key = SecretKey(utf8.encode(apiKey)) {
    if ([
      apiKeyId,
      sessionId,
      apiKey,
    ].any((v) => v.isEmpty || v.contains(RegExp(r'[\r\n]')))) {
      throw ArgumentError('Invalid session credentials');
    }
  }

  final String apiKeyId, sessionId;
  final SecretKey key;
  // Deliberately no toJson/toString containing authentication material.
}

class RequestStamp {
  RequestStamp({String? timestamp, String? nonce, String? requestId})
    : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch.toString(),
      nonce = nonce ?? 'nonce_${_randomId()}',
      requestId = requestId ?? 'request_${_randomId()}';

  final String timestamp, nonce, requestId;
  String get salt => '$timestamp:$nonce';

  static String _randomId() {
    final random = Random.secure();
    return b64(List.generate(24, (_) => random.nextInt(256)));
  }
}

/// HTTPS is mandatory; proxy path prefixes are preserved.
Uri serviceBase(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError(
      'An HTTPS service base without credentials is required',
    );
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> unb64(String value) => base64Url.decode(base64Url.normalize(value));
Future<String> sha256Hex(String text) async =>
    (await Sha256().hash(utf8.encode(text))).bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();

Future<SecretKey> derive(SecretKey key, String salt, String info) => Hkdf(
  hmac: Hmac.sha256(),
  outputLength: 32,
).deriveKey(secretKey: key, nonce: utf8.encode(salt), info: utf8.encode(info));

Future<String> sign(SecretKey key, String canonical) async => b64(
  (await Hmac.sha256().calculateMac(
    utf8.encode(canonical),
    secretKey: key,
  )).bytes,
);

bool equalSignature(String expected, String received) {
  final a = unb64(expected), b = unb64(received);
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ (i < b.length ? b[i] : 0);
  }
  return difference == 0;
}

Map<String, dynamic> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected an object');
  }
  return value;
}

Future<Map<String, String>> encrypt(SecretKey key, Object? value) async {
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(value)),
    secretKey: key,
  );
  // Insertion order is part of the server's JSON.stringify signature contract.
  return {
    'iv': b64(box.nonce),
    'ciphertext': b64(box.cipherText),
    'tag': b64(box.mac.bytes),
  };
}

Future<Object?> decrypt(SecretKey key, Object? value) async {
  final payload = jsonObject(value);
  final iv = unb64(payload['iv'] as String);
  final tag = unb64(payload['tag'] as String);
  if (iv.length != 12 || tag.length != 16) {
    throw const FormatException('Invalid encrypted payload');
  }
  final bytes = await AesGcm.with256bits().decrypt(
    SecretBox(unb64(payload['ciphertext'] as String), nonce: iv, mac: Mac(tag)),
    secretKey: key,
  );
  return jsonDecode(utf8.decode(bytes));
}

/// A separate response key per request prevents cross-request response reuse.
class SealedRequest {
  const SealedRequest(this.headers, this.body, this._responseKey);
  final Map<String, String> headers;
  final Map<String, dynamic> body;
  final SecretKey _responseKey;

  Future<Object?> openResponse(Map<String, dynamic> response) async {
    if (response['status'] != 1 || response['code'] != 'success') {
      throw const FormatException('Unsuccessful response envelope');
    }
    return decrypt(_responseKey, response['data']);
  }
}

Future<SealedRequest> sealRequest({
  required CcsopCredentials credentials,
  required String interfaceId,
  required Map<String, dynamic> params,
  RequestStamp? stamp,
}) async {
  if (!RegExp(r'^[A-Z]\d{6,64}$').hasMatch(interfaceId)) {
    throw ArgumentError('Invalid interface ID');
  }
  final s = stamp ?? RequestStamp();
  Future<SecretKey> key(String purpose) => derive(
    credentials.key,
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
    credentials.apiKeyId,
    credentials.sessionId,
    s.timestamp,
    s.nonce,
    s.requestId,
    await sha256Hex(jsonEncode(data)),
  ].join('\n');
  return SealedRequest(
    Map.unmodifiable({
      'x-api-key-id': credentials.apiKeyId,
      'x-session-id': credentials.sessionId,
      'x-timestamp': s.timestamp,
      'x-nonce': s.nonce,
      'x-request-id': s.requestId,
    }),
    {'data': data, 'sign': await sign(await key('sign'), canonical)},
    await key('response'),
  );
}
