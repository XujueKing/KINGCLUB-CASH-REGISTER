import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_cancellation.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_result_test.dart' show checkout;

Map<String, dynamic> cancellationFixture(TableCheckoutCommand command) => {
  'result': {
    'state': 'cancelled_unsent',
    'checkoutRef': checkout,
    'receipt': {
      'version': 1,
      'state': 'cancelled_unsent',
      'scope': {
        'checkoutRef': checkout,
        'requestId': command.requestId,
        'employeeRef': command.employeeRef,
        'storeRef': command.storeRef,
        'tableRef': command.tableRef,
        'sessionRef': command.sessionRef,
        'channel': command.channel,
        'accountType': command.accountType,
        'currency': 'CNY',
        'totalCents': command.totalCents,
        'snapshotFingerprint': command.fingerprint,
      },
      'orderCount': command.orderCount,
      'orderRefs': ['D00000000001', 'D00000000002'],
      'cancelledAt': '2026-09-30T00:00:00.000Z',
    },
  },
};
void main() {
  test('only complete matched cancellation permits journal removal; other originals survive', () async {
    final command = fixture.command(),
        storage = staff.TestStorage(),
        session = staff.session();
    final journal = TableCheckoutJournal(storage: storage);
    final other = TableCheckoutCommand.decode({
      ...command.encoded,
      'sessionRef': 'OTHER_SESSION',
      'requestId': '00000000-0000-4000-8000-000000000098',
    });
    await journal.save(session, command);
    await journal.save(session, other);
    final missing = TableCheckoutCancellation.parse(
      {
        'result': {'state': 'not_cancelled', 'checkoutRef': checkout},
      },
      command,
      checkoutRef: checkout,
    );
    await expectLater(
      journal.acknowledgeCancellation(session, command, missing),
      throwsA(isA<CcsopFailure>()),
    );
    final result = TableCheckoutCancellation.parse(
      cancellationFixture(command),
      command,
      checkoutRef: checkout,
    );
    await expectLater(
      journal.acknowledgeCancellation(session, other, result),
      throwsA(isA<CcsopFailure>()),
    );
    expect(await journal.load(session), hasLength(2));
    await journal.acknowledgeCancellation(session, command, result);
    await journal.acknowledgeCancellation(session, command, result);
    expect((await journal.load(session)).single.encoded, other.encoded);
  });
  test('rejects metadata-only, wrong scope, malformed amount/time and noncanonical orders', () {
    final command = fixture.command();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (raw) => raw['result'].remove('receipt'),
      (raw) => raw['result']['state'] = 'closed',
      (raw) =>
          raw['result']['receipt']['scope']['employeeRef'] = 'E00000000002',
      (raw) => raw['result']['receipt']['scope']['storeRef'] = 'OTHER',
      (raw) =>
          raw['result']['receipt']['scope']['accountType'] = 'platform_cash',
      (raw) => raw['result']['receipt']['scope']['totalCents'] = 300.0,
      (raw) =>
          raw['result']['receipt']['scope']['snapshotFingerprint'] = 'b' * 64,
      (raw) => raw['result']['receipt']['orderRefs'] = [
        'D00000000001',
        'D00000000001',
      ],
      (raw) => raw['result']['receipt']['orderRefs'] = [
        'D00000000002',
        'D00000000001',
      ],
      (raw) =>
          raw['result']['receipt']['cancelledAt'] = '2026-02-30T00:00:00.000Z',
    ]) {
      final raw = cancellationFixture(command);
      mutate(raw);
      expect(
        () => TableCheckoutCancellation.parse(
          raw,
          command,
          checkoutRef: checkout,
        ),
        throwsA(isA<CcsopFailure>()),
      );
    }
  });
}
