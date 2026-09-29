import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'ccsop_crypto.dart';

/// Authenticated CCSOP frame codec, not a store subscription or a socket owner.
/// Create a new instance for every connection, even when reconnecting a session.
class CcsopRealtimeCodec {
  CcsopRealtimeCodec(
    this._credentials,
    this.clientId, {
    RequestStamp? stamp,
    this.endpoint = '/ws',
  }) : stamp = stamp ?? RequestStamp() {
    if (clientId.isEmpty || clientId.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Invalid realtime client identifier');
    }
    if (!{'/ws', '/cashier/ws'}.contains(endpoint)) {
      throw ArgumentError('Invalid realtime endpoint');
    }
  }

  final CcsopCredentials _credentials;
  final String clientId;
  final String endpoint;
  final RequestStamp stamp;
  final _keys = <String, Future<SecretKey>>{};
  int _receivedSequence = 0, _sentSequence = 0;
  Future<void> _inbound = Future.value(), _outbound = Future.value();
  bool _closed = false;

  Future<SecretKey> _key(String purpose) => _keys.putIfAbsent(
    purpose,
    () => derive(
      _credentials.key,
      stamp.salt,
      'ccsop:websocket:$purpose:${stamp.requestId}',
    ),
  );

  void _checkOpen() {
    if (_closed) throw StateError('Realtime codec is closed');
  }

  Future<Uri> connectionUri(String base) async {
    _checkOpen();
    final root = serviceBase(base);
    final canonical = [
      'GET',
      endpoint,
      _credentials.apiKeyId,
      _credentials.sessionId,
      stamp.timestamp,
      stamp.nonce,
      stamp.requestId,
      await sha256Hex(clientId),
    ].join('\n');
    final signature = await sign(await _key('sign'), canonical);
    _checkOpen();
    // This URI contains signed session material. Never log it.
    return root.replace(
      scheme: 'wss',
      path: '${root.path}$endpoint',
      queryParameters: {
        'apiKeyId': _credentials.apiKeyId,
        'sessionId': _credentials.sessionId,
        'timestamp': stamp.timestamp,
        'nonce': stamp.nonce,
        'requestId': stamp.requestId,
        'clientId': clientId,
        'sign': signature,
      },
    );
  }

  /// Serialize crypto operations: async completions must not reorder sequences.
  Future<String> encode(String eventType, Map<String, dynamic> payload) {
    final next = _outbound.then((_) async {
      _checkOpen();
      if (eventType.isEmpty || eventType.contains(RegExp(r'[\r\n]'))) {
        throw ArgumentError('Invalid event type');
      }
      final seq = ++_sentSequence;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final data = await encrypt(await _key('client-to-server'), payload);
      final canonical = [
        eventType,
        seq,
        timestamp,
        '',
        await sha256Hex(jsonEncode(data)),
      ].join('\n');
      final signature = await sign(await _key('message-sign'), canonical);
      _checkOpen();
      return jsonEncode({
        'eventType': eventType,
        'encrypted': true,
        'data': data,
        'sign': signature,
        'seq': seq,
        'timestamp': timestamp,
      });
    });
    _outbound = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Map<String, dynamic>> decode(String raw) {
    final next = _inbound.then((_) async {
      _checkOpen();
      if (raw.length > 1024 * 1024) {
        throw const FormatException('Frame too large');
      }
      final frame = jsonObject(jsonDecode(raw));
      final seq = frame['seq'];
      if (frame['encrypted'] != true ||
          seq is! int ||
          seq <= _receivedSequence ||
          frame['timestamp'] is! int ||
          frame['eventType'] is! String ||
          (frame['eventType'] as String).isEmpty ||
          (frame['traceId'] != null && frame['traceId'] is! String)) {
        throw const FormatException('Invalid realtime frame');
      }
      final data = jsonObject(frame['data']);
      final canonical = [
        frame['eventType'],
        seq,
        frame['timestamp'],
        frame['traceId'] ?? '',
        await sha256Hex(jsonEncode(data)),
      ].join('\n');
      if (!equalSignature(
        await sign(await _key('message-sign'), canonical),
        frame['sign'] as String,
      )) {
        throw const FormatException('Invalid realtime signature');
      }
      final payload = await decrypt(await _key('server-to-client'), data);
      _checkOpen();
      _receivedSequence =
          seq; // Only advance after authentication and decryption.
      return {...frame, 'data': payload};
    });
    _inbound = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void close() {
    _closed = true;
    _keys.clear();
  }
}
