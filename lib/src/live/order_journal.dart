import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'order_command.dart';

/// Same-isolate serialized encrypted envelope. No automatic purge, plaintext fallback or retry.
class OrderJournal {
  OrderJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const storageKey = 'pending_staff_orders_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) async {
      try {
        return await work();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('ORDER_JOURNAL_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PendingOrder>> _read() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return [];
    if (raw.length > 4000000) throw const FormatException();
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 2 ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > 100) {
      throw const FormatException();
    }
    final entries = (value['entries'] as List)
        .map(PendingOrder.decode)
        .toList();
    if (entries
                .map((e) => jsonEncode([e.base, e.employeeRef, e.requestId]))
                .toSet()
                .length !=
            entries.length ||
        entries
                .map((e) => jsonEncode([e.base, e.storeRef, e.tableRef]))
                .toSet()
                .length !=
            entries.length) {
      throw const FormatException();
    }
    return entries;
  }

  Future<void> _write(List<PendingOrder> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.encode()).toList(),
    });
    if (raw.length > 4000000) throw const CcsopFailure('ORDER_JOURNAL_FULL');
    await _storage.write(storageKey, raw);
    if (await _storage.read(storageKey) != raw) {
      throw const CcsopFailure('ORDER_JOURNAL_UNAVAILABLE');
    }
  }

  Future<List<PendingOrder>> load(StaffSession identity) => _serial(
    () async =>
        List.unmodifiable((await _read()).where((e) => e.belongsTo(identity))),
  );
  Future<void> save(PendingOrder command, StaffSession identity) => _serial(
    () async {
      if (!command.belongsTo(identity)) {
        throw const CcsopFailure('ORDER_SCOPE_CHANGED');
      }
      final entries = await _read();
      for (final old in entries) {
        if (old.signature == command.signature) return;
        if (old.base == command.base &&
            ((old.storeRef == command.storeRef &&
                    old.tableRef == command.tableRef) ||
                (old.employeeRef == command.employeeRef &&
                    old.requestId == command.requestId))) {
          throw const CcsopFailure('ORDER_ALREADY_PENDING');
        }
      }
      if (entries.length >= 100) throw const CcsopFailure('ORDER_JOURNAL_FULL');
      await _write([...entries, command]);
    },
  );
  Future<void> acknowledge(StaffSession identity, OrderRequestResult result) =>
      _serial(() async {
        if (result.state == OrderRequestState.notObserved) {
          throw const CcsopFailure('ORDER_RESULT_UNCONFIRMED');
        }
        final entries = await _read(),
            matches = entries
                .where((e) => e.signature == result.commandSignature)
                .toList();
        if (matches.isEmpty) return;
        if (matches.length != 1 || !matches.single.belongsTo(identity)) {
          throw const CcsopFailure('ORDER_SCOPE_CHANGED');
        }
        await _write(
          entries.where((e) => e.signature != result.commandSignature).toList(),
        );
      });
}
