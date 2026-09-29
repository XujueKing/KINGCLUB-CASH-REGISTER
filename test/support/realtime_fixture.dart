import 'dart:async';
import 'dart:convert';

import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/network/cashier_socket.dart';
import 'package:kingclub_cash_register/src/network/ccsop_crypto.dart';

StaffSession realtimeSession() {
  final now = DateTime.now();
  return StaffSession.fromServer(
    {
      'employee': {
        'employeeRef': 'E00000000001',
        'displayName': 'Test employee',
      },
      'storeRef': 'test-store',
      'sessionId': '00000000-0000-4000-8000-000000000002',
      'apiKeyId': '00000000-0000-4000-8000-000000000003',
      'apiKey': 'a' * 43,
      'refreshToken': 'b' * 43,
      'permissions': ['workbench.read'],
      'expiresAtMs': now
          .add(const Duration(minutes: 15))
          .millisecondsSinceEpoch,
      'refreshExpiresAtMs': now
          .add(const Duration(hours: 12))
          .millisecondsSinceEpoch,
    },
    base: 'https://service.invalid/prefix',
    deviceId: '00000000-0000-4000-8000-000000000001',
    expectedStore: 'test-store',
  );
}

class TestCashierSocket implements CashierSocket {
  final inbound = StreamController<Object?>();
  final sent = <String>[];
  bool closed = false;
  @override
  Stream<Object?> get messages => inbound.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closed = true;
    unawaited(inbound.close());
  }
}

// Explicit protocol fixture, never part of the application transport.
Future<String> serverFrame(
  StaffSession session,
  Uri uri,
  int sequence,
  String event,
  Map<String, dynamic> payload, {
  int? timestamp,
}) async {
  final query = uri.queryParameters;
  final salt = '${query['timestamp']}:${query['nonce']}';
  final request = query['requestId'];
  final data = await encrypt(
    await derive(
      session.credentials.key,
      salt,
      'ccsop:websocket:server-to-client:$request',
    ),
    payload,
  );
  final time = timestamp ?? DateTime.now().millisecondsSinceEpoch;
  final signature = await sign(
    await derive(
      session.credentials.key,
      salt,
      'ccsop:websocket:message-sign:$request',
    ),
    [event, sequence, time, '', await sha256Hex(jsonEncode(data))].join('\n'),
  );
  return jsonEncode({
    'eventType': event,
    'encrypted': true,
    'data': data,
    'sign': signature,
    'seq': sequence,
    'timestamp': time,
  });
}
