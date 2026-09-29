import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/opening_journal.dart';
import 'package:kingclub_cash_register/src/live/opening_snapshot.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'opening_snapshot_test.dart' as fixture;
import 'staff_session_test.dart' as auth;

class WriteStorage extends auth.TestStorage {
  bool dropWrite = false, throwAfterWrite = false;
  @override
  Future<void> write(String key, String value) async {
    if (dropWrite) return;
    await super.write(key, value);
    if (throwAfterWrite) throw StateError('TEST ONLY uncertain storage result');
  }
}

final identity = auth.session({
  ...auth.response(),
  'permissions': ['workbench.read', 'table.open'],
});
PendingOpening pending({String table = 'test-table'}) => PendingOpening.prepare(
  session: identity,
  context: OpeningContext.parse(
    {
      'result': {
        ...fixture.context(),
        'openingEnabled': true,
        'tableId': table,
      },
    },
    storeRef: 'test-store',
    tableId: table,
  ),
  partySize: 2,
  memberRefs: ['test-member'],
  arrivalConfirmed: true,
  reservationChecked: true,
);
OpeningLookup confirmed(
  PendingOpening p, [
  Map<String, dynamic> patch = const {},
]) => OpeningLookup.parse(
  {
    'result': {
      'state': 'confirmed',
      'requestId': p.requestId,
      'receipt': {...fixture.receipt(), 'tableId': p.tableId, ...patch},
    },
  },
  storeRef: p.storeRef,
  tableId: p.tableId,
  requestId: p.requestId,
);

void main() {
  test(
    'lost write is detected; write-then-error can be recovered after restart',
    () async {
      final storage = WriteStorage()..dropWrite = true;
      final journal = OpeningJournal(storage: storage), p = pending();
      await expectLater(
        journal.save(p, identity),
        throwsA(isA<CcsopFailure>()),
      );
      expect(await journal.load(identity), isEmpty);
      storage.dropWrite = false;
      storage.throwAfterWrite = true;
      await expectLater(
        journal.save(p, identity),
        throwsA(isA<CcsopFailure>()),
      );
      storage.throwAfterWrite = false;
      expect(
        (await OpeningJournal(storage: storage).load(identity))
            .single
            .requestId,
        p.requestId,
      );
    },
  );
  test(
    'logout clears credentials but retains unresolved opening journal',
    () async {
      final storage = auth.TestStorage(), p = pending();
      final journal = OpeningJournal(storage: storage);
      final c = auth.controller(storage, auth.TestAuth(), auth.TestApi());
      await auth.login(c);
      await journal.save(p, identity);
      await c.logout();
      expect((await journal.load(identity)).single.requestId, p.requestId);
      c.dispose();
    },
  );
  test(
    'restart restores exact immutable request without credentials',
    () async {
      final storage = auth.TestStorage(), p = pending();
      await OpeningJournal(storage: storage).save(p, identity);
      final restored = (await OpeningJournal(storage: storage).load(identity))
          .single;
      expect(restored.requestId, p.requestId);
      expect(restored.params, p.params);
      expect(() => restored.params['partySize'] = 9, throwsUnsupportedError);
      expect(
        () => (restored.params['memberRefs'] as List).add('another'),
        throwsUnsupportedError,
      );
      final saved = storage.data[OpeningJournal.storageKey]!;
      expect(saved, isNot(contains('a' * 43)));
      expect(saved, isNot(contains('refreshToken')));
    },
  );
  test(
    'same request save is idempotent, new request cannot overwrite unknown',
    () async {
      final storage = auth.TestStorage(),
          journal = OpeningJournal(storage: auth.TestStorage());
      final p = pending();
      await journal.save(p, identity);
      await journal.save(p, identity);
      await expectLater(
        journal.save(pending(), identity),
        throwsA(isA<CcsopFailure>()),
      );
      expect((await journal.load(identity)).single.requestId, p.requestId);
      expect(storage.data, isEmpty);
    },
  );
  test(
    'parallel writers preserve different tables and reject a double click',
    () async {
      final storage = auth.TestStorage();
      final first = OpeningJournal(storage: storage),
          second = OpeningJournal(storage: storage);
      await Future.wait([
        first.save(pending(), identity),
        second.save(pending(table: 'table-2'), identity),
      ]);
      expect(await first.load(identity), hasLength(2));
      final a = pending(table: 'table-3'), b = pending(table: 'table-3');
      await first.save(a, identity);
      await expectLater(second.save(b, identity), throwsA(isA<CcsopFailure>()));
      expect(await first.load(identity), hasLength(3));
    },
  );
  test(
    'other employee cannot view, overwrite, or clear unresolved opening',
    () async {
      final storage = auth.TestStorage(), p = pending();
      final journal = OpeningJournal(storage: storage);
      final other = auth.session({
        ...auth.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': 'Test'},
      });
      await journal.save(p, identity);
      expect(await journal.load(other), isEmpty);
      await expectLater(journal.save(p, other), throwsA(isA<CcsopFailure>()));
      await expectLater(
        journal.acknowledge(other, confirmed(p)),
        throwsA(isA<CcsopFailure>()),
      );
      expect(await journal.load(identity), hasLength(1));
    },
  );
  test(
    'only confirmed matching receipt clears; repeated acknowledgement is safe',
    () async {
      final storage = auth.TestStorage(), p = pending();
      final journal = OpeningJournal(storage: storage);
      await journal.save(p, identity);
      final unknown = OpeningLookup.parse(
        {
          'result': {'state': 'not_observed', 'requestId': p.requestId},
        },
        storeRef: p.storeRef,
        tableId: p.tableId,
        requestId: p.requestId,
      );
      await expectLater(
        journal.acknowledge(identity, unknown),
        throwsA(isA<CcsopFailure>()),
      );
      for (final patch in [
        <String, dynamic>{
          'memberRefs': ['other'],
        },
        {'businessDate': '2026-09-28'},
        {'paymentTiming': 'prepay'},
      ]) {
        await expectLater(
          journal.acknowledge(identity, confirmed(p, patch)),
          throwsA(isA<CcsopFailure>()),
        );
      }
      expect(await journal.load(identity), hasLength(1));
      await journal.acknowledge(identity, confirmed(p));
      await journal.acknowledge(identity, confirmed(p));
      expect(await journal.load(identity), isEmpty);
    },
  );
  test('corrupt storage is retained and blocks new commands', () async {
    final storage = auth.TestStorage();
    final journal = OpeningJournal(storage: storage);
    for (final encoded in [
      'not-json',
      '{"version":2,"entries":[]}',
      jsonEncode({
        'version': 1,
        'entries': [
          {'params': {}},
        ],
      }),
    ]) {
      storage.data[OpeningJournal.storageKey] = encoded;
      await expectLater(journal.load(identity), throwsA(isA<CcsopFailure>()));
      await expectLater(
        journal.save(pending(), identity),
        throwsA(isA<CcsopFailure>()),
      );
      expect(storage.data[OpeningJournal.storageKey], encoded);
    }
  });
  test(
    'storage failure never reports a prepared command as safely saved',
    () async {
      final storage = auth.TestStorage()..fail = true;
      final journal = OpeningJournal(storage: storage);
      await expectLater(
        journal.save(pending(), identity),
        throwsA(isA<CcsopFailure>()),
      );
      storage.fail = false;
      expect(await journal.load(identity), isEmpty);
    },
  );
  test(
    'confirmation is explicit; no command when disabled or already occupied',
    () {
      for (final patch in [
        <String, dynamic>{'openingEnabled': false},
        {
          'activeSession': {'sessionRef': 'H00000000001', 'status': 'open'},
        },
      ]) {
        expect(
          () => PendingOpening.prepare(
            session: identity,
            context: fixture.parseContext({
              ...fixture.context(),
              'openingEnabled': true,
              ...patch,
            }),
            partySize: 2,
            memberRefs: [],
            arrivalConfirmed: true,
            reservationChecked: true,
          ),
          throwsA(isA<CcsopFailure>()),
        );
      }
      expect(
        () => PendingOpening.prepare(
          session: identity,
          context: fixture.parseContext({
            ...fixture.context(),
            'openingEnabled': true,
          }),
          partySize: 2,
          memberRefs: [],
          arrivalConfirmed: false,
          reservationChecked: true,
        ),
        throwsA(isA<CcsopFailure>()),
      );
    },
  );
}
