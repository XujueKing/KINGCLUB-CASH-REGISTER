import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';

/// One unresolved original request per store/order. Survives logout and restart.
/// No customer payment code, merchant credential or login token is persisted.
class ProviderRefundJournal {
  ProviderRefundJournal(this.identity, this.orderRef, {SecretStorage? storage})
    : storage = storage ?? PlatformSecretStorage();
  final StaffSession identity;
  final String orderRef;
  final SecretStorage storage;
  String get key =>
      'provider_refund_v1_${base64Url.encode(utf8.encode(jsonEncode([identity.base.toString(), identity.storeRef, orderRef])))}';
  Future<Map<String, dynamic>?> read() async {
    final raw = await storage.read(key);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['employeeRef'] is! String ||
        value['command'] is! Map)
      throw const FormatException('REFUND_JOURNAL_INVALID');
    final command = Map<String, dynamic>.from(value['command'] as Map);
    if (command['orderRef'] != orderRef ||
        command['action'] != 'refund' ||
        command['requestId'] is! String ||
        command['productRef'] is! String)
      throw const FormatException('REFUND_JOURNAL_INVALID');
    if (!uuidPattern.hasMatch(command['requestId'] as String)) {
      throw const FormatException('REFUND_JOURNAL_INVALID');
    }
    return {'employeeRef': value['employeeRef'], 'command': command};
  }

  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> save(Map<String, dynamic> command) => _serial(() async {
    if (await read() != null)
      throw const FormatException('REFUND_ALREADY_PENDING');
    final raw = jsonEncode({
      'employeeRef': identity.employeeRef,
      'command': command,
    });
    await storage.write(key, raw);
    if (await storage.read(key) != raw)
      throw const FormatException('REFUND_JOURNAL_UNAVAILABLE');
  });

  Future<void> acknowledge(String requestId) => _serial(() async {
    final prior = await read();
    if (prior == null) return;
    if ((prior['command'] as Map)['requestId'] != requestId)
      throw const FormatException('REFUND_JOURNAL_CONFLICT');
    await storage.delete(key);
    if (await storage.read(key) != null)
      throw const FormatException('REFUND_JOURNAL_UNAVAILABLE');
  });
}
