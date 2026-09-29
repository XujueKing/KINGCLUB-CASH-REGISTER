import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'table_clear_command.dart';

/// Same-isolate serialized secure envelope. No timeout purge, logout cleanup or plaintext fallback.
class TableClearJournal {
  TableClearJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const storageKey = 'pending_staff_table_clear_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) async {
      try {
        return await work();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('TABLE_CLEAR_JOURNAL_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PendingTableClear>> _read() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return [];
    if (raw.length > 1000000) throw const FormatException();
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 2 ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > 100) {
      throw const FormatException();
    }
    final entries = (value['entries'] as List)
        .map(PendingTableClear.decode)
        .toList();
    if (entries.map((e) => e.requestKey).toSet().length != entries.length ||
        entries.map((e) => e.sessionKey).toSet().length != entries.length) {
      throw const FormatException();
    }
    return entries;
  }

  Future<void> _write(List<PendingTableClear> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.encode()).toList(),
    });
    if (raw.length > 1000000) {
      throw const CcsopFailure('TABLE_CLEAR_JOURNAL_FULL');
    }
    await _storage.write(storageKey, raw);
    if (await _storage.read(storageKey) != raw) {
      throw const CcsopFailure('TABLE_CLEAR_JOURNAL_UNAVAILABLE');
    }
  }

  Future<List<PendingTableClear>> load(StaffSession identity) => _serial(
    () async =>
        List.unmodifiable((await _read()).where((e) => e.belongsTo(identity))),
  );
  Future<void> save(PendingTableClear command, StaffSession identity) =>
      _serial(() async {
        if (!command.belongsTo(identity)) {
          throw const CcsopFailure('TABLE_CLEAR_SCOPE_CHANGED');
        }
        final entries = await _read();
        if (entries.any((e) => e.signature == command.signature)) return;
        if (entries.any(
          (e) =>
              e.sessionKey == command.sessionKey ||
              e.requestKey == command.requestKey,
        )) {
          throw const CcsopFailure('TABLE_CLEAR_ALREADY_PENDING');
        }
        if (entries.length >= 100) {
          throw const CcsopFailure('TABLE_CLEAR_JOURNAL_FULL');
        }
        await _write([...entries, command]);
      });
  Future<void> acknowledge(StaffSession identity, TableClearResult result) =>
      _serial(() async {
        if (!result.confirmed) {
          throw const CcsopFailure('TABLE_CLEAR_RESULT_UNCONFIRMED');
        }
        final entries = await _read(),
            matching = entries
                .where((e) => e.signature == result.commandSignature)
                .toList();
        if (matching.isEmpty) return;
        if (matching.length != 1 || !matching.single.belongsTo(identity)) {
          throw const CcsopFailure('TABLE_CLEAR_SCOPE_CHANGED');
        }
        await _write(
          entries.where((e) => e.signature != result.commandSignature).toList(),
        );
      });
}
