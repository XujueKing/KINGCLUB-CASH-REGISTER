import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'cash_command.dart';

/// Serialized secure storage, read-back verified before any caller may send a money decision.
class CashJournal {
  CashJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const storageKey = 'pending_staff_cash_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) async {
      try {
        return await work();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('CASH_JOURNAL_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PendingCash>> _read() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return [];
    if (raw.length > 1000000) throw const FormatException();
    final v = jsonDecode(raw);
    if (v is! Map ||
        v.length != 2 ||
        v['version'] != 1 ||
        v['entries'] is! List ||
        (v['entries'] as List).length > 100) {
      throw const FormatException();
    }
    final entries = (v['entries'] as List).map(PendingCash.decode).toList();
    if (entries
                .map((e) => jsonEncode([e.base, e.employeeRef, e.requestId]))
                .toSet()
                .length !=
            entries.length ||
        entries
                .map((e) => jsonEncode([e.base, e.storeRef, e.orderRef]))
                .toSet()
                .length !=
            entries.length) {
      throw const FormatException();
    }
    return entries;
  }

  Future<void> _write(List<PendingCash> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.encode()).toList(),
    });
    if (raw.length > 1000000) throw const CcsopFailure('CASH_JOURNAL_FULL');
    await _storage.write(storageKey, raw);
    if (await _storage.read(storageKey) != raw) {
      throw const CcsopFailure('CASH_JOURNAL_UNAVAILABLE');
    }
  }

  Future<List<PendingCash>> load(StaffSession identity) => _serial(
    () async =>
        List.unmodifiable((await _read()).where((e) => e.belongsTo(identity))),
  );
  Future<void> save(
    PendingCash next,
    StaffSession identity, {
    PendingCash? previous,
  }) => _serial(() async {
    if (!next.belongsTo(identity) ||
        (previous != null &&
            (!previous.belongsTo(identity) || !next.follows(previous)))) {
      throw const CcsopFailure('CASH_SCOPE_CHANGED');
    }
    final entries = await _read();
    if (entries.any((e) => e.signature == next.signature)) return;
    if (previous != null) {
      final index = entries.indexWhere(
        (e) => e.signature == previous.signature,
      );
      if (index < 0) throw const CcsopFailure('CASH_JOURNAL_CHANGED');
      entries[index] = next;
      await _write(entries);
      return;
    }
    if (!next.initial) throw const CcsopFailure('CASH_JOURNAL_CHANGED');
    if (entries.any(
      (e) =>
          e.base == next.base &&
          ((e.storeRef == next.storeRef && e.orderRef == next.orderRef) ||
              (e.employeeRef == next.employeeRef &&
                  e.requestId == next.requestId)),
    )) {
      throw const CcsopFailure('CASH_ALREADY_PENDING');
    }
    if (entries.length >= 100) throw const CcsopFailure('CASH_JOURNAL_FULL');
    await _write([...entries, next]);
  });
  Future<void> acknowledge(StaffSession identity, CashResult result) => _serial(
    () async {
      if (!result.terminal) throw const CcsopFailure('CASH_RESULT_UNCONFIRMED');
      final entries = await _read(),
          found = entries
              .where((e) => e.signature == result.commandSignature)
              .toList();
      if (found.isEmpty) return;
      if (found.length != 1 || !found.single.belongsTo(identity)) {
        throw const CcsopFailure('CASH_SCOPE_CHANGED');
      }
      await _write(
        entries.where((e) => e.signature != result.commandSignature).toList(),
      );
    },
  );
}
