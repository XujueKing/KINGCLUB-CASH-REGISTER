import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/cash_command.dart';
import 'package:kingclub_cash_register/src/live/cash_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;

final identity = a.session({
  ...a.response(),
  'permissions': ['workbench.read', 'payment.cash'],
});
const intent = '00000000-0000-4000-8000-000000000001';
PendingCash command() => PendingCash.prepare(
  identity: identity,
  orderRef: 'D00000000001',
  totalCents: 100,
  now: a.now,
);
Map<String, dynamic> prepared(PendingCash c) => {
  'storeRef': c.storeRef,
  'orderRef': c.orderRef,
  'requestId': c.requestId,
  'intentRef': intent,
  'channel': 'cash',
  'currency': 'CNY',
  'totalCents': c.totalCents,
  'intentStatus': 'prepared',
};
Map<String, dynamic> observed(PendingCash c) => {
  'state': 'prepared',
  'storeRef': c.storeRef,
  'orderRef': c.orderRef,
  'requestId': c.requestId,
  'intentRef': intent,
  'currency': 'CNY',
  'totalCents': 100,
  'paymentTiming': 'prepay',
  'canConfirmCash': true,
};
PendingCash bound(PendingCash c) => c.observe(
  CashResult.parse({'result': prepared(c)}, c, response: CashResponse.prepare),
);
Map<String, dynamic> receipt(PendingCash c) => {
  'storeRef': c.storeRef,
  'orderRef': c.orderRef,
  'intentRef': intent,
  'totalCents': 100,
  'currency': 'CNY',
  'channel': 'cash',
  'paymentRef': 'cash:$intent',
  'receivedCents': 200,
  'changeCents': 100,
  'confirmedBy': c.employeeRef,
  'confirmationStatus': 'confirmed',
};
Map<String, dynamic> closure(PendingCash c) => {
  'storeRef': c.storeRef,
  'orderRef': c.orderRef,
  'intentRef': intent,
  'requestId': c.requestId,
  'totalCents': 100,
  'currency': 'CNY',
  'channel': 'cash',
  'closedBy': c.employeeRef,
  'noCashCollectedConfirmed': true,
  'closureStatus': 'closed',
};
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

class Storage extends a.TestStorage {
  bool drop = false, uncertain = false;
  @override
  Future<void> write(String key, String value) async {
    if (drop) return;
    await super.write(key, value);
    if (uncertain) throw StateError('TEST_ONLY');
  }
}

void main() {
  test(
    'other employee cannot see or overwrite pending cash on same order',
    () async {
      final storage = Storage(),
          journal = CashJournal(storage: storage),
          c = command();
      final other = a.session({
        ...a.response(),
        'employee': {
          'employeeRef': 'E00000000002',
          'displayName': 'TEST OTHER',
        },
        'permissions': ['workbench.read', 'payment.cash'],
      });
      await journal.save(c, identity);
      expect(await journal.load(other), isEmpty);
      await expectLater(journal.save(c, other), fails('CASH_SCOPE_CHANGED'));
      final second = PendingCash.prepare(
        identity: other,
        orderRef: c.orderRef,
        totalCents: 100,
        now: a.now,
      );
      await expectLater(
        journal.save(second, other),
        fails('CASH_ALREADY_PENDING'),
      );
      expect((await journal.load(identity)).single.signature, c.signature);
    },
  );
  test('verified closure removes only its durable decision entry', () async {
    final storage = Storage(),
        journal = CashJournal(storage: storage),
        c = command();
    await journal.save(c, identity);
    final b = bound(c);
    await journal.save(b, identity, previous: c);
    final closed = b.recordClosure(noCashCollectedConfirmed: true);
    await journal.save(closed, identity, previous: b);
    final result = CashResult.parse(
      {
        'result': {
          'state': 'closed',
          'requestId': closed.requestId,
          'receipt': closure(closed),
        },
      },
      closed,
      response: CashResponse.lookup,
    );
    await journal.acknowledge(identity, result);
    expect(await journal.load(identity), isEmpty);
  });
  test('original command roundtrip immutable, no credentials, fresh requests differ', () {
    final c = command();
    expect(
      PendingCash.decode(jsonDecode(jsonEncode(c.encode()))).signature,
      c.signature,
    );
    expect(c.requestId, isNot(command().requestId));
    expect(() => c.params['currency'] = 'USD', throwsUnsupportedError);
    expect(
      c.encode().keys,
      unorderedEquals([
        'base',
        'employeeRef',
        'deviceId',
        'params',
        'intentRef',
        'receivedCents',
        'closeRequested',
      ]),
    );
  });
  test('requires current cash authority and real amount/order shape', () {
    expect(
      () => PendingCash.prepare(
        identity: a.session(a.response()),
        orderRef: 'D00000000001',
        totalCents: 100,
        now: a.now,
      ),
      fails('CASH_SCOPE_CHANGED'),
    );
    expect(
      () => PendingCash.prepare(
        identity: identity,
        orderRef: 'D00000000001',
        totalCents: 100,
        now: identity.expiresAt,
      ),
      fails('CASH_SCOPE_CHANGED'),
    );
    expect(
      () => PendingCash.prepare(
        identity: identity,
        orderRef: 'bad',
        totalCents: 100,
        now: a.now,
      ),
      fails('CASH_COMMAND_INVALID'),
    );
  });
  test('prepared response is never paid, even replayed confirmed status requires lookup', () {
    final c = command();
    for (final status in [
      'prepared',
      'pending',
      'unknown',
      'confirmed',
      'closed',
    ]) {
      final r = CashResult.parse(
        {
          'result': {...prepared(c), 'intentStatus': status},
        },
        c,
        response: CashResponse.prepare,
      );
      expect(r.state, CashState.needsLookup);
      expect(r.terminal, false);
      expect(r.canConfirmCash, false);
    }
  });
  test('lookup permits prepared or unknown without terminal success', () {
    final c = command();
    expect(
      CashResult.parse(
        {'result': observed(c)},
        c,
        response: CashResponse.lookup,
      ).canConfirmCash,
      true,
    );
    expect(
      CashResult.parse(
        {
          'result': {...observed(c), 'canConfirmCash': false},
        },
        c,
        response: CashResponse.lookup,
      ).canConfirmCash,
      false,
    );
    expect(
      CashResult.parse(
        {
          'result': {'state': 'not_observed', 'requestId': c.requestId},
        },
        c,
        response: CashResponse.lookup,
      ).terminal,
      false,
    );
    expect(
      () => CashResult.parse(
        {
          'result': {'state': 'not_observed', 'requestId': c.requestId},
        },
        bound(c),
        response: CashResponse.lookup,
      ),
      fails('CASH_RECEIPT_MISMATCH'),
    );
  });
  test('cash decision is explicit, irreversible and amount-stable', () {
    final c = bound(command()),
        pay = c.recordConfirmation(200, cashReceivedConfirmed: true),
        cancel = c.recordClosure(noCashCollectedConfirmed: true);
    expect(pay.confirm['receivedCents'], 200);
    expect(cancel.close['noCashCollectedConfirmed'], true);
    expect(
      () => c.recordConfirmation(200, cashReceivedConfirmed: false),
      fails('CASH_DECISION_CONFLICT'),
    );
    expect(
      () => pay.recordClosure(noCashCollectedConfirmed: true),
      fails('CASH_DECISION_CONFLICT'),
    );
    expect(
      () => cancel.recordConfirmation(200, cashReceivedConfirmed: true),
      fails('CASH_DECISION_CONFLICT'),
    );
    expect(
      () => pay.recordConfirmation(201, cashReceivedConfirmed: true),
      fails('CASH_DECISION_CONFLICT'),
    );
    expect(() => command().confirm, fails('CASH_DECISION_REQUIRED'));
  });
  test('exact paid/closed receipts alone are terminal', () {
    final c = bound(command()),
        pay = c.recordConfirmation(200, cashReceivedConfirmed: true),
        cancel = c.recordClosure(noCashCollectedConfirmed: true);
    final paid = CashResult.parse(
      {'result': receipt(pay)},
      pay,
      response: CashResponse.confirm,
    );
    expect(paid.state, CashState.confirmed);
    expect(paid.changeCents, 100);
    expect(
      CashResult.parse(
        {
          'result': {
            'state': 'confirmed',
            'requestId': pay.requestId,
            'receipt': receipt(pay),
          },
        },
        pay,
        response: CashResponse.lookup,
      ).terminal,
      true,
    );
    expect(
      CashResult.parse(
        {'result': closure(cancel)},
        cancel,
        response: CashResponse.close,
      ).state,
      CashState.closed,
    );
    expect(
      () => CashResult.parse(
        {'result': receipt(c)},
        c,
        response: CashResponse.confirm,
      ),
      fails('CASH_RECEIPT_MISMATCH'),
    );
    expect(
      () => CashResult.parse(
        {'result': closure(c)},
        c,
        response: CashResponse.close,
      ),
      fails('CASH_RECEIPT_MISMATCH'),
    );
  });
  for (final patch in <Map<String, dynamic>>[
    {'changeCents': 99},
    {'receivedCents': 201},
    {'confirmedBy': 'E00000000002'},
    {'totalCents': 101},
    {'orderRef': 'D00000000002'},
    {'channel': 'alipay'},
    {'paymentRef': 'fake'},
    {'extra': true},
  ]) {
    test('rejects mismatched payment evidence $patch', () {
      final c = bound(command())
          .recordConfirmation(200, cashReceivedConfirmed: true);
      expect(
        () => CashResult.parse(
          {
            'result': {...receipt(c), ...patch},
          },
          c,
          response: CashResponse.confirm,
        ),
        fails('CASH_RECEIPT_MISMATCH'),
      );
    });
  }
  test('journal persists each decision, cannot reverse with stale command, acknowledges exact final receipt', () async {
    final storage = Storage(),
        journal = CashJournal(storage: storage),
        c = command();
    await journal.save(c, identity);
    final b = bound(c);
    await journal.save(b, identity, previous: c);
    final pay = b.recordConfirmation(200, cashReceivedConfirmed: true);
    await journal.save(pay, identity, previous: b);
    expect(
      (await CashJournal(storage: storage).load(identity)).single.signature,
      pay.signature,
    );
    await expectLater(
      journal.save(
        b.recordClosure(noCashCollectedConfirmed: true),
        identity,
        previous: b,
      ),
      fails('CASH_JOURNAL_CHANGED'),
    );
    await expectLater(
      journal.save(b, identity, previous: pay),
      fails('CASH_SCOPE_CHANGED'),
    );
    final result = CashResult.parse(
      {'result': receipt(pay)},
      pay,
      response: CashResponse.confirm,
    );
    await journal.acknowledge(identity, result);
    expect(await journal.load(identity), isEmpty);
  });
  test(
    'same-order new request blocked and not_observed does not clear original',
    () async {
      final storage = Storage(),
          journal = CashJournal(storage: storage),
          c = command();
      await journal.save(c, identity);
      await expectLater(
        journal.save(command(), identity),
        fails('CASH_ALREADY_PENDING'),
      );
      final result = CashResult.parse(
        {
          'result': {'state': 'not_observed', 'requestId': c.requestId},
        },
        c,
        response: CashResponse.lookup,
      );
      await expectLater(
        journal.acknowledge(identity, result),
        fails('CASH_RESULT_UNCONFIRMED'),
      );
      expect((await journal.load(identity)).single.requestId, c.requestId);
    },
  );
  test('missing or uncertain write is not treated as durable; persisted original remains recoverable', () async {
    final storage = Storage()..drop = true,
        journal = CashJournal(storage: storage),
        c = command();
    await expectLater(
      journal.save(c, identity),
      fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    storage.uncertain = true;
    await expectLater(
      journal.save(c, identity),
      fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    storage.uncertain = false;
    expect((await journal.load(identity)).single.signature, c.signature);
  });
  test('corrupt storage is preserved and blocks further requests', () async {
    final storage = Storage()..data[CashJournal.storageKey] = '{',
        journal = CashJournal(storage: storage);
    await expectLater(
      journal.load(identity),
      fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    await expectLater(
      journal.save(command(), identity),
      fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    expect(storage.data[CashJournal.storageKey], '{');
  });
  test('concurrent journals serialize and cannot overwrite another pending request', () async {
    final storage = Storage(),
        one = CashJournal(storage: storage),
        two = CashJournal(storage: storage);
    final outcomes = await Future.wait([
      one
          .save(command(), identity)
          .then((_) => true, onError: (Object _) => false),
      two
          .save(command(), identity)
          .then((_) => true, onError: (Object _) => false),
    ]);
    expect(outcomes.where((v) => v).length, 1);
    expect(await one.load(identity), hasLength(1));
  });
}
