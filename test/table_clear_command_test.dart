import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/table_clear_command.dart';
import 'package:kingclub_cash_register/src/live/table_clear_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

final identity = a.session({
  ...a.response(),
  'permissions': ['workbench.read', 'table.clear'],
});
PendingTableClear command({
  StaffSession? staff,
  String session = 'H00000000001',
  bool confirmed = true,
}) => PendingTableClear.prepare(
  identity: staff ?? identity,
  tableRef: 'TEST_TABLE',
  sessionRef: session,
  now: a.now,
  confirmed: confirmed,
);
Map<String, dynamic> receipt(PendingTableClear c) => {
  ...c.lookup,
  'clearedBy': c.employeeRef,
  'closedAt': '2026-09-29T00:00:00.000Z',
  'closureStatus': 'closed',
  'paidOrderCount': 1,
  'expiredOrderCount': 0,
  'settledCents': 200,
  'departedSeatCount': 2,
};
Map<String, dynamic> result(PendingTableClear c) => {
  'result': {
    'state': 'confirmed',
    'requestId': c.requestId,
    'receipt': receipt(c),
  },
};
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

void main() {
  test('accepts the same 1000-order receipt boundary as the server', () {
    final c = command(), payload = result(c);
    final r = payload['result']['receipt'] as Map<String, dynamic>;
    r['paidOrderCount'] = 1000;
    r['settledCents'] = 100000000000;
    expect(TableClearResult.parse(payload, c).confirmed, isTrue);
    r['expiredOrderCount'] = 1;
    expect(
      () => TableClearResult.parse(payload, c),
      fails('TABLE_CLEAR_RESPONSE_INVALID'),
    );
  });
  test('refunded orders are counted separately from net paid settlement', () {
    final c = command();
    final payload = result(c);
    final r = payload['result']['receipt'] as Map<String, dynamic>;
    r['paidOrderCount'] = 0;
    r['settledCents'] = 0;
    r['refundedOrderCount'] = 1;
    expect(TableClearResult.parse(payload, c).confirmed, isTrue);
    for (final invalid in [0, -1, 1001, '1', 1.5]) {
      r['refundedOrderCount'] = invalid;
      expect(
        () => TableClearResult.parse(payload, c),
        fails('TABLE_CLEAR_RESPONSE_INVALID'),
      );
    }
    r['refundedOrderCount'] = 1000;
    r['expiredOrderCount'] = 1;
    expect(
      () => TableClearResult.parse(payload, c),
      fails('TABLE_CLEAR_RESPONSE_INVALID'),
    );
  });
  test('canonical immutable command requires explicit confirmation and current permission', () {
    final c = command();
    expect(
      PendingTableClear.decode(jsonDecode(jsonEncode(c.encode()))).signature,
      c.signature,
    );
    expect(c.requestId, isNot(command().requestId));
    expect(c.params.length, 5);
    expect(c.lookup.length, 4);
    expect(() => c.params['clearConfirmed'] = false, throwsUnsupportedError);
    expect(c.signature, isNot(contains('apiKey')));
    expect(c.signature, isNot(contains('refreshToken')));
    expect(
      () => command(confirmed: false),
      fails('TABLE_CLEAR_CONFIRMATION_REQUIRED'),
    );
    expect(
      () => command(staff: a.session()),
      fails('TABLE_CLEAR_SCOPE_CHANGED'),
    );
  });
  test('strict decoding rejects forged permission, totals, confirmation and bad scope', () {
    final c = command();
    for (final patch in <Map<String, dynamic>>[
      {'clearConfirmed': false},
      {'clearConfirmed': 1},
      {'clearConfirmed': 'true'},
      {'sessionRef': 'bad'},
      {'tableRef': ''},
      {'storeRef': 'bad /store'},
      {'requestId': 'bad'},
      {'orders': []},
      {'settledCents': 200},
      {'employeeRef': 'E00000000002'},
    ]) {
      expect(
        () => PendingTableClear.decode({
          ...c.encode(),
          'params': {...c.params, ...patch},
        }),
        fails('TABLE_CLEAR_COMMAND_INVALID'),
      );
    }
    for (final base in [
      'http://service.invalid',
      'https://user:pass@service.invalid',
      'https://service.invalid?x=1',
    ]) {
      expect(
        () => PendingTableClear.decode({...c.encode(), 'base': base}),
        fails('TABLE_CLEAR_COMMAND_INVALID'),
      );
    }
  });
  test('only exact original receipt is success, not a current table state', () {
    final c = command(), verified = TableClearResult.parse(result(c), c);
    expect(verified.confirmed, true);
    expect(
      () => verified.receipt!['closureStatus'] = 'open',
      throwsUnsupportedError,
    );
    for (final patch in <Map<String, dynamic>>[
      {'clearedBy': 'E00000000002'},
      {'storeRef': 'OTHER'},
      {'sessionRef': 'H00000000002'},
      {'requestId': command().requestId},
      {'closureStatus': 'open'},
      {'paidOrderCount': 1.0},
      {'paidOrderCount': 0},
      {'paidOrderCount': 1000, 'expiredOrderCount': 1},
      {'settledCents': 0},
      {'settledCents': 100000000001},
      {'paidOrderCount': 1, 'settledCents': 100000001},
      {'departedSeatCount': -1},
      {'departedSeatCount': true},
      {'closedAt': '2026-02-30T00:00:00.000Z'},
      {'closedAt': '2026-09-29'},
      {'closedAt': null},
      {'extra': true},
    ]) {
      expect(
        () => TableClearResult.parse({
          'result': {
            'state': 'confirmed',
            'requestId': c.requestId,
            'receipt': {...receipt(c), ...patch},
          },
        }, c),
        fails('TABLE_CLEAR_RESPONSE_INVALID'),
      );
    }
    expect(
      TableClearResult.parse({
        'result': {'state': 'not_observed', 'requestId': c.requestId},
      }, c).confirmed,
      false,
    );
    expect(
      () => TableClearResult.parse({
        'result': {
          'state': 'not_observed',
          'requestId': c.requestId,
          'closed': true,
        },
      }, c),
      fails('TABLE_CLEAR_RESPONSE_INVALID'),
    );
  });
  test('durable save survives a new journal; not observed cannot clear; confirmed removes only original', () async {
    final storage = Storage(),
        j = TableClearJournal(storage: storage),
        c = command(),
        other = command(session: 'H00000000002');
    await j.save(c, identity);
    await j.save(other, identity);
    final resumed = TableClearJournal(storage: storage);
    expect((await resumed.load(identity)).length, 2);
    await expectLater(
      resumed.acknowledge(
        identity,
        TableClearResult.parse({
          'result': {'state': 'not_observed', 'requestId': c.requestId},
        }, c),
      ),
      fails('TABLE_CLEAR_RESULT_UNCONFIRMED'),
    );
    await resumed.acknowledge(identity, TableClearResult.parse(result(c), c));
    expect((await j.load(identity)).single.signature, other.signature);
    await resumed.acknowledge(identity, TableClearResult.parse(result(c), c));
    expect((await j.load(identity)).single.signature, other.signature);
  });
  test('concurrent journals serialize, same session cannot gain a second original request', () async {
    final storage = Storage(),
        a = TableClearJournal(storage: storage),
        b = TableClearJournal(storage: storage),
        c = command();
    await Future.wait([a.save(c, identity), b.save(c, identity)]);
    expect((await a.load(identity)).length, 1);
    await expectLater(
      b.save(command(), identity),
      fails('TABLE_CLEAR_ALREADY_PENDING'),
    );
  });
  test(
    'another employee cannot inspect, replace or acknowledge prior staff work',
    () async {
      final storage = Storage(),
          journal = TableClearJournal(storage: storage),
          c = command();
      final other = a.session({
        ...a.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': 'TEST ONLY'},
        'permissions': ['workbench.read', 'table.clear'],
      });
      await journal.save(c, identity);
      expect(await journal.load(other), isEmpty);
      await expectLater(
        journal.save(c, other),
        fails('TABLE_CLEAR_SCOPE_CHANGED'),
      );
      await expectLater(
        journal.save(command(staff: other), other),
        fails('TABLE_CLEAR_ALREADY_PENDING'),
      );
      await expectLater(
        journal.acknowledge(other, TableClearResult.parse(result(c), c)),
        fails('TABLE_CLEAR_SCOPE_CHANGED'),
      );
      expect((await journal.load(identity)).single.signature, c.signature);
    },
  );
  test('readback failure and write-then-error preserve uncertainty without fallback', () async {
    final storage = Storage(),
        journal = TableClearJournal(storage: storage),
        c = command();
    storage.drop = true;
    await expectLater(
      journal.save(c, identity),
      fails('TABLE_CLEAR_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    storage.uncertain = true;
    await expectLater(
      journal.save(c, identity),
      fails('TABLE_CLEAR_JOURNAL_UNAVAILABLE'),
    );
    storage.uncertain = false;
    expect((await journal.load(identity)).single.signature, c.signature);
    final done = TableClearResult.parse(result(c), c);
    storage.drop = true;
    await expectLater(
      journal.acknowledge(identity, done),
      fails('TABLE_CLEAR_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    expect((await journal.load(identity)).single.signature, c.signature);
  });
  test(
    'corrupt or duplicate envelope fails closed and is not purged',
    () async {
      final storage = Storage(),
          journal = TableClearJournal(storage: storage),
          c = command();
      for (final raw in [
        '{',
        jsonEncode({
          'version': 1,
          'entries': [c.encode(), c.encode()],
        }),
        jsonEncode({'version': 2, 'entries': []}),
      ]) {
        storage.data[TableClearJournal.storageKey] = raw;
        await expectLater(journal.load(identity), throwsA(isA<CcsopFailure>()));
        expect(storage.data[TableClearJournal.storageKey], raw);
      }
    },
  );
  test('capacity is bounded and request UUID cannot be reused for a different session', () async {
    final storage = Storage(),
        journal = TableClearJournal(storage: storage),
        c = command();
    await journal.save(c, identity);
    final reused = PendingTableClear.decode({
      ...c.encode(),
      'params': {...c.params, 'tableRef': 'OTHER'},
    });
    await expectLater(
      journal.save(reused, identity),
      fails('TABLE_CLEAR_ALREADY_PENDING'),
    );
    final entries = List.generate(
      100,
      (i) => command(session: 'H${i.toString().padLeft(11, '0')}').encode(),
    );
    storage.data[TableClearJournal.storageKey] = jsonEncode({
      'version': 1,
      'entries': entries,
    });
    await expectLater(
      journal.save(command(session: 'H99999999999'), identity),
      fails('TABLE_CLEAR_JOURNAL_FULL'),
    );
    expect((await journal.load(identity)).length, 100);
  });
}
