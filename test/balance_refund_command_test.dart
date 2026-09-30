import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_command.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_context.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'staff_session_test.dart' as a;
import 'balance_refund_context_test.dart' as context_test;

final identity = a.session({
  ...a.response(),
  'permissions': ['workbench.read', 'payment.refund'],
});
BalanceRefundContext context() => BalanceRefundContext.parse(
  {...context_test.fixture(), 'storeRef': identity.storeRef},
  expectedStore: identity.storeRef,
  expectedOrder: 'D00000000001',
);
List<Map<String, dynamic>> choices() => [
  {
    'originalMovementRef': 'M00000000001',
    'returnQuantity': 0,
    'physicalReturnConfirmed': false,
    'reason': 'TEST_ONLY consumed',
  },
];
PendingBalanceRefund command({
  List<Map<String, dynamic>>? dispositions,
  bool confirmed = true,
}) => PendingBalanceRefund.prepare(
  identity: identity,
  context: context(),
  now: a.now,
  confirmed: confirmed,
  reason: ' TEST_ONLY refund ',
  dispositions: dispositions ?? choices(),
);
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

class Storage implements SecretStorage {
  final data = <String, String>{};
  bool failWrite = false, discardWrite = false;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('TEST_STORAGE');
    if (!discardWrite) data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (key == BalanceRefundJournal.storageKey) {
      throw StateError('Must not delete pending refund');
    }
    data.remove(key);
  }
}

void main() {
  test('round trip retains exact request and deeply immutable choices', () {
    final c = command(),
        restored = PendingBalanceRefund.decode(
          jsonDecode(jsonEncode(c.encode())),
        );
    expect(restored.signature, c.signature);
    expect(c.params['reason'], 'TEST_ONLY refund');
    expect(c.params['refundRef'], isNot(c.params['originalIntentRef']));
    expect(
      () => (c.params['dispositions'] as List).first['returnQuantity'] = 1,
      throwsUnsupportedError,
    );
    expect(c.encode().keys, isNot(contains('apiKey')));
  });
  test(
    'requires explicit decision and every original issue without over-return',
    () {
      expect(
        () => command(confirmed: false),
        fails('BALANCE_REFUND_CONFIRMATION_REQUIRED'),
      );
      final over = choices()..single['returnQuantity'] = 3;
      over.single['physicalReturnConfirmed'] = true;
      expect(
        () => command(dispositions: over),
        fails('BALANCE_REFUND_DISPOSITION_INVALID'),
      );
      final missing = choices()..single['originalMovementRef'] = 'M00000000002';
      expect(
        () => command(dispositions: missing),
        fails('BALANCE_REFUND_DISPOSITION_INVALID'),
      );
      final unconfirmed = choices()..single['returnQuantity'] = 1;
      expect(
        () => command(dispositions: unconfirmed),
        fails('BALANCE_REFUND_COMMAND_INVALID'),
      );
    },
  );
  test('rejects payer injection and same original/refund ID', () {
    final c = command();
    expect(
      () => PendingBalanceRefund.decode({
        ...c.encode(),
        'params': {...c.params, 'userAccount': 'TEST_MEMBER'},
      }),
      fails('BALANCE_REFUND_COMMAND_INVALID'),
    );
    expect(
      () => PendingBalanceRefund.decode({
        ...c.encode(),
        'params': {...c.params, 'refundRef': c.params['originalIntentRef']},
      }),
      fails('BALANCE_REFUND_COMMAND_INVALID'),
    );
  });
  test('survives a new journal instance without changing request', () async {
    final storage = Storage(), c = command();
    await BalanceRefundJournal(storage: storage).save(c, identity);
    final next = BalanceRefundJournal(storage: storage);
    expect((await next.load(identity)).single.signature, c.signature);
    await next.save(c, identity);
    expect(await next.load(identity), hasLength(1));
    await expectLater(
      next.save(command(), identity),
      fails('BALANCE_REFUND_ALREADY_PENDING'),
    );
  });
  test('serializes concurrent conflicting requests', () async {
    final journal = BalanceRefundJournal(storage: Storage());
    final first = journal.save(command(), identity);
    final rejected = expectLater(
      journal.save(command(), identity),
      fails('BALANCE_REFUND_ALREADY_PENDING'),
    );
    await first;
    await rejected;
    expect(await journal.load(identity), hasLength(1));
  });
  test(
    'changed employee cannot load or bypass pending original order',
    () async {
      final storage = Storage(),
          journal = BalanceRefundJournal(storage: storage),
          c = command();
      await journal.save(c, identity);
      final other = a.session({
        ...a.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': '测试员工'},
        'permissions': ['workbench.read', 'payment.refund'],
      });
      expect(await journal.load(other), isEmpty);
      await expectLater(
        journal.save(c, other),
        fails('BALANCE_REFUND_SCOPE_CHANGED'),
      );
      final changed = PendingBalanceRefund.decode({
        ...c.encode(),
        'employeeRef': other.employeeRef,
      });
      await expectLater(
        journal.save(changed, other),
        fails('BALANCE_REFUND_ALREADY_PENDING'),
      );
    },
  );
  test('storage failure or failed readback prevents successful save', () async {
    for (final discard in [false, true]) {
      final storage = Storage()
        ..failWrite = !discard
        ..discardWrite = discard;
      await expectLater(
        BalanceRefundJournal(storage: storage).save(command(), identity),
        fails('BALANCE_REFUND_JOURNAL_UNAVAILABLE'),
      );
    }
  });
  test('corrupt storage is preserved, never silently reset', () async {
    final storage = Storage()..data[BalanceRefundJournal.storageKey] = '{bad';
    final journal = BalanceRefundJournal(storage: storage);
    await expectLater(
      journal.load(identity),
      fails('BALANCE_REFUND_JOURNAL_UNAVAILABLE'),
    );
    await expectLater(
      journal.save(command(), identity),
      fails('BALANCE_REFUND_JOURNAL_UNAVAILABLE'),
    );
    expect(storage.data[BalanceRefundJournal.storageKey], '{bad');
  });
}
