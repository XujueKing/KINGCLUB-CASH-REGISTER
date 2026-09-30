import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_result_test.dart' as result_fixture;

import 'package:kingclub_cash_register/src/live/table_checkout_result.dart';

void main() {
  test('only original settlement removes one record and acknowledgement is idempotent', () async {
    final storage = staff.TestStorage(),
        session = staff.session(),
        command = fixture.command();
    final journal = TableCheckoutJournal(storage: storage);
    await journal.save(session, command);
    final other = TableCheckoutCommand.decode({
      ...command.encoded,
      'sessionRef': 'OTHER_SESSION',
      'requestId': '00000000-0000-4000-8000-000000000098',
    });
    await journal.save(session, other);
    final pending = TableCheckoutResult.parse(
      {
        'result': {
          'state': 'settlement_pending',
          'checkoutRef': result_fixture.checkout,
        },
      },
      command,
      checkoutRef: result_fixture.checkout,
    );
    await expectLater(
      journal.acknowledge(session, command, pending),
      throwsA(isA<CcsopFailure>()),
    );
    expect(await journal.load(session), hasLength(2));
    final settled = TableCheckoutResult.parse(
      result_fixture.settlementFixture(command),
      command,
      checkoutRef: result_fixture.checkout,
    );
    await expectLater(
      journal.acknowledge(session, other, settled),
      throwsA(isA<CcsopFailure>()),
    );
    await journal.acknowledge(session, command, settled);
    await journal.acknowledge(session, command, settled);
    expect((await journal.load(session)).single.encoded, other.encoded);
  });
  test('persists original request and permits only identical replay', () async {
    final storage = staff.TestStorage(),
        session = staff.session(),
        command = fixture.command();
    final journal = TableCheckoutJournal(storage: storage);
    await journal.save(session, command);
    await journal.save(session, command);
    expect(
      (await TableCheckoutJournal(storage: storage).load(session))
          .single
          .encoded,
      command.encoded,
    );
    final changed = TableCheckoutCommand.decode({
      ...command.encoded,
      'requestId': '00000000-0000-4000-8000-000000000098',
    });
    await expectLater(
      journal.save(session, changed),
      throwsA(isA<CcsopFailure>()),
    );
    expect(
      storage.data[TableCheckoutJournal.key],
      isNot(contains('paymentCode')),
    );
    expect(storage.data[TableCheckoutJournal.key], isNot(contains('apiKey')));
  });
  test(
    'separates employees and refuses unavailable or corrupted storage',
    () async {
      final storage = staff.TestStorage(),
          journal = TableCheckoutJournal(storage: storage);
      await journal.save(staff.session(), fixture.command());
      final other = staff.session({
        ...staff.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': '测试员工二'},
      });
      expect(await journal.load(other), isEmpty);
      storage.data[TableCheckoutJournal.key] = 'invalid';
      await expectLater(
        journal.load(staff.session()),
        throwsA(isA<CcsopFailure>()),
      );
      storage.fail = true;
      await expectLater(
        journal.save(staff.session(), fixture.command()),
        throwsA(isA<CcsopFailure>()),
      );
    },
  );
}
