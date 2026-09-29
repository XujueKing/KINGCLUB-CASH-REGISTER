import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/serving_command.dart';
import 'package:kingclub_cash_register/src/live/serving_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

final identity = a.session({
  ...a.response(),
  'permissions': ['workbench.read', 'orders.serve'],
});
PendingServing command({
  StaffSession? staff,
  String product = 'TEST_PRODUCT',
  bool confirmed = true,
}) => PendingServing.prepare(
  identity: staff ?? identity,
  tableRef: 'TEST_TABLE',
  sessionRef: 'H00000000001',
  orderRef: 'D00000000001',
  productRef: product,
  quantity: 4,
  expectedServedQuantity: 1,
  targetServedQuantity: 3,
  now: a.now,
  confirmed: confirmed,
);
Map<String, dynamic> receipt(PendingServing c) => {
  ...c.lookup,
  'servedBy': c.employeeRef,
  'servedBefore': c.before,
  'servedAfter': c.after,
  'deliveredQuantity': c.after - c.before,
  'remainingQuantity': c.quantity - c.after,
  'complete': c.after == c.quantity,
};
Map<String, dynamic> result(PendingServing c) => {
  'result': {
    'state': 'confirmed',
    'requestId': c.requestId,
    'receipt': receipt(c),
  },
};
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

void main() {
  test('original command canonical roundtrip immutable, scoped and free of credentials', () {
    final c = command();
    expect(
      PendingServing.decode(jsonDecode(jsonEncode(c.encode()))).signature,
      c.signature,
    );
    expect(c.requestId, isNot(command().requestId));
    expect(c.params.length, 8);
    expect(c.lookup.length, 6);
    expect(() => c.params['targetServedQuantity'] = 4, throwsUnsupportedError);
    expect(() => c.lookup['storeRef'] = 'OTHER', throwsUnsupportedError);
    expect(c.signature, isNot(contains('apiKey')));
    expect(c.signature, isNot(contains('refreshToken')));
    expect(
      () => command(confirmed: false),
      fails('SERVING_CONFIRMATION_REQUIRED'),
    );
    expect(() => command(staff: a.session()), fails('SERVING_SCOPE_CHANGED'));
  });
  test(
    'strict source counters and scope cannot be rewritten while decoding',
    () {
      final c = command();
      for (final patch in <Map<String, dynamic>>[
        {'expectedServedQuantity': true},
        {'targetServedQuantity': 1},
        {'targetServedQuantity': 5},
        {'targetServedQuantity': 3.0},
        {'storeRef': 'bad /store'},
        {'sessionRef': 'other'},
        {'orderRef': 'D1'},
        {'productRef': ''},
        {'employeeRef': 'E00000000002'},
      ]) {
        expect(
          () => PendingServing.decode({
            ...c.encode(),
            'params': {...c.params, ...patch},
          }),
          fails('SERVING_COMMAND_INVALID'),
        );
      }
      for (final base in [
        'http://service.invalid',
        'https://user:pass@service.invalid',
        'https://service.invalid?secret=x',
      ]) {
        expect(
          () => PendingServing.decode({...c.encode(), 'base': base}),
          fails('SERVING_COMMAND_INVALID'),
        );
      }
    },
  );
  test('only exact confirmed receipt clears uncertainty, never a matching current quantity', () {
    final c = command();
    expect(ServingResult.parse(result(c), c).confirmed, true);
    final unknown = ServingResult.parse({
      'result': {'state': 'not_observed', 'requestId': c.requestId},
    }, c);
    expect(unknown.confirmed, false);
    for (final patch in <Map<String, dynamic>>[
      {'servedBy': 'E00000000002'},
      {'storeRef': 'OTHER'},
      {'productRef': 'OTHER'},
      {'requestId': command().requestId},
      {'servedBefore': 0},
      {'servedAfter': 4},
      {'deliveredQuantity': 3},
      {'remainingQuantity': 0},
      {'complete': true},
      {'servedBefore': 1.0},
      {'extra': true},
    ]) {
      expect(
        () => ServingResult.parse({
          'result': {
            'state': 'confirmed',
            'requestId': c.requestId,
            'receipt': {...receipt(c), ...patch},
          },
        }, c),
        fails('SERVING_RESPONSE_INVALID'),
      );
    }
    expect(
      () => ServingResult.parse({
        'result': {
          'state': 'not_observed',
          'requestId': c.requestId,
          'servedQuantity': 3,
        },
      }, c),
      fails('SERVING_RESPONSE_INVALID'),
    );
  });
  test('durable save survives a new journal; not observed cannot clear; confirmed removes only original', () async {
    final storage = Storage(),
        j = ServingJournal(storage: storage),
        c = command(),
        other = command(product: 'OTHER');
    await j.save(c, identity);
    await j.save(other, identity);
    final resumed = ServingJournal(storage: storage);
    expect((await resumed.load(identity)).length, 2);
    await expectLater(
      resumed.acknowledge(
        identity,
        ServingResult.parse({
          'result': {'state': 'not_observed', 'requestId': c.requestId},
        }, c),
      ),
      fails('SERVING_RESULT_UNCONFIRMED'),
    );
    await resumed.acknowledge(identity, ServingResult.parse(result(c), c));
    expect((await j.load(identity)).single.signature, other.signature);
    await resumed.acknowledge(identity, ServingResult.parse(result(c), c));
    expect((await j.load(identity)).single.signature, other.signature);
  });
  test('concurrent journals serialize, same line cannot gain a second original request', () async {
    final storage = Storage(),
        a = ServingJournal(storage: storage),
        b = ServingJournal(storage: storage),
        c = command();
    await Future.wait([a.save(c, identity), b.save(c, identity)]);
    expect((await a.load(identity)).length, 1);
    await expectLater(
      b.save(command(), identity),
      fails('SERVING_ALREADY_PENDING'),
    );
  });
  test(
    'another employee cannot inspect, replace or acknowledge prior staff work',
    () async {
      final storage = Storage(),
          journal = ServingJournal(storage: storage),
          c = command();
      final other = a.session({
        ...a.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': 'TEST ONLY'},
        'permissions': ['workbench.read', 'orders.serve'],
      });
      await journal.save(c, identity);
      expect(await journal.load(other), isEmpty);
      await expectLater(journal.save(c, other), fails('SERVING_SCOPE_CHANGED'));
      await expectLater(
        journal.save(command(staff: other), other),
        fails('SERVING_ALREADY_PENDING'),
      );
      await expectLater(
        journal.acknowledge(other, ServingResult.parse(result(c), c)),
        fails('SERVING_SCOPE_CHANGED'),
      );
      expect((await journal.load(identity)).single.signature, c.signature);
    },
  );
  test('readback failure and write-then-error preserve uncertainty without fallback', () async {
    final storage = Storage(),
        journal = ServingJournal(storage: storage),
        c = command();
    storage.drop = true;
    await expectLater(
      journal.save(c, identity),
      fails('SERVING_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    storage.uncertain = true;
    await expectLater(
      journal.save(c, identity),
      fails('SERVING_JOURNAL_UNAVAILABLE'),
    );
    storage.uncertain = false;
    expect((await journal.load(identity)).single.signature, c.signature);
    final done = ServingResult.parse(result(c), c);
    storage.drop = true;
    await expectLater(
      journal.acknowledge(identity, done),
      fails('SERVING_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    expect((await journal.load(identity)).single.signature, c.signature);
  });
  test(
    'corrupt or duplicate envelope fails closed and is not purged',
    () async {
      final storage = Storage(),
          journal = ServingJournal(storage: storage),
          c = command();
      for (final raw in [
        '{',
        jsonEncode({
          'version': 1,
          'entries': [c.encode(), c.encode()],
        }),
        jsonEncode({'version': 2, 'entries': []}),
      ]) {
        storage.data[ServingJournal.storageKey] = raw;
        await expectLater(journal.load(identity), throwsA(isA<CcsopFailure>()));
        expect(storage.data[ServingJournal.storageKey], raw);
      }
    },
  );
  test('capacity is bounded and request UUID cannot be reused for a different line', () async {
    final storage = Storage(),
        journal = ServingJournal(storage: storage),
        c = command();
    await journal.save(c, identity);
    final reused = PendingServing.decode({
      ...c.encode(),
      'params': {...c.params, 'productRef': 'OTHER'},
    });
    await expectLater(
      journal.save(reused, identity),
      fails('SERVING_ALREADY_PENDING'),
    );
    final entries = List.generate(100, (i) => command(product: 'P$i').encode());
    storage.data[ServingJournal.storageKey] = jsonEncode({
      'version': 1,
      'entries': entries,
    });
    await expectLater(
      journal.save(command(product: 'NEW'), identity),
      fails('SERVING_JOURNAL_FULL'),
    );
    expect((await journal.load(identity)).length, 100);
  });
}
