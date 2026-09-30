import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'table_checkout_command.dart';
import 'table_checkout_result.dart';
import 'table_checkout_cancellation.dart';

/// Original requests only. Unknown outcomes survive logout/restart; removal
/// requires a strictly validated original server settlement or unsent cancellation.
class TableCheckoutJournal {
  TableCheckoutJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const key = 'pending_staff_table_checkout_v1';
  static Future<void> _tail = Future.value();
  String _scope(TableCheckoutCommand row) =>
      jsonEncode([row.base, row.storeRef, row.sessionRef]);
  String _request(TableCheckoutCommand row) =>
      jsonEncode([row.base, row.employeeRef, row.requestId]);
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) async {
      try {
        return await work();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<TableCheckoutCommand>> _read() async {
    final text = await _storage.read(key);
    if (text == null) return [];
    if (text.length > 1000000) {
      throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_INVALID');
    }
    final raw = jsonDecode(text);
    if (raw is! List || raw.length > 100) {
      throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_INVALID');
    }
    final rows = raw.map(TableCheckoutCommand.decode).toList();
    if (rows.map(_scope).toSet().length != rows.length ||
        rows.map(_request).toSet().length != rows.length) {
      throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_INVALID');
    }
    return rows;
  }

  Future<List<TableCheckoutCommand>> load(StaffSession session) => _serial(
    () async => List.unmodifiable(
      (await _read()).where((row) => row.belongsTo(session)),
    ),
  );
  Future<void> acknowledge(
    StaffSession session,
    TableCheckoutCommand command,
    TableCheckoutResult result,
  ) => _serial(() async {
    if (!command.belongsTo(session) ||
        !result.settled ||
        !result.matches(command)) {
      throw const CcsopFailure('TABLE_CHECKOUT_SETTLEMENT_REQUIRED');
    }
    await _remove(command);
  });
  Future<void> acknowledgeCancellation(
    StaffSession session,
    TableCheckoutCommand command,
    TableCheckoutCancellation result,
  ) => _serial(() async {
    if (!command.belongsTo(session) ||
        !result.cancelled ||
        !result.matches(command)) {
      throw const CcsopFailure('TABLE_CHECKOUT_CANCELLATION_REQUIRED');
    }
    await _remove(command);
  });
  Future<void> _remove(TableCheckoutCommand command) async {
    final rows = await _read();
    final matches = rows
        .where(
          (row) =>
              _scope(row) == _scope(command) ||
              _request(row) == _request(command),
        )
        .toList();
    if (matches.isEmpty) return;
    if (matches.length != 1 ||
        jsonEncode(matches.single.encoded) != jsonEncode(command.encoded)) {
      throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_CHANGED');
    }
    rows.remove(matches.single);
    final encoded = jsonEncode(rows.map((row) => row.encoded).toList());
    await _storage.write(key, encoded);
    if (await _storage.read(key) != encoded) {
      throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_UNAVAILABLE');
    }
  }

  Future<void> save(StaffSession session, TableCheckoutCommand command) =>
      _serial(() async {
        if (!command.belongsTo(session)) {
          throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
        }
        final rows = await _read();
        final prior = rows
            .where(
              (row) =>
                  _scope(row) == _scope(command) ||
                  _request(row) == _request(command),
            )
            .toList();
        if (prior.isNotEmpty) {
          if (prior.length == 1 &&
              jsonEncode(prior.single.encoded) == jsonEncode(command.encoded)) {
            return;
          }
          throw const CcsopFailure('TABLE_CHECKOUT_ORIGINAL_REQUEST_REQUIRED');
        }
        if (rows.length >= 100) {
          throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_FULL');
        }
        rows.add(command);
        final encoded = jsonEncode(rows.map((row) => row.encoded).toList());
        if (encoded.length > 1000000) {
          throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_FULL');
        }
        await _storage.write(key, encoded);
        if (await _storage.read(key) != encoded) {
          throw const CcsopFailure('TABLE_CHECKOUT_JOURNAL_UNAVAILABLE');
        }
      });
}
