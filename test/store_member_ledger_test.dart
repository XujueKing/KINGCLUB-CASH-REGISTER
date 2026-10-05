import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/store_member_ledger.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  test('statement time uses local store date without ISO suffix or milliseconds', () {
    expect(statementTime('2026-10-05T16:01:02.123Z'), '2026-10-06 00:01:02');
    expect(statementTime(null), '—');
  });
  testWidgets('statement shows credits and debits, complete reference and after balance', (t) async {
    t.view.physicalSize = const Size(1366,768); t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topRight,
      child: SizedBox(width: 925,child: StoreMemberLedger(language: UiLanguage.en,memberNumber: 'KM_TEST',rows: [
        {'rowRef':'3','occurredAt':'2026-10-05T16:01:02.000Z','operationRef':'00000000-0000-4000-8000-000000000009',
         'item':'consumption','paymentMethod':'store_balance','incomeCents':'0','expenseCents':'20000','balanceAfterCents':'90000'},
        {'rowRef':'2','occurredAt':'2026-10-05T15:01:02.000Z','operationRef':'TEST_RECHARGE','item':'recharge_gift',
         'paymentMethod':'gift','incomeCents':'10000','expenseCents':'0','balanceAfterCents':'110000'},
      ])),
    ))));
    expect(find.text('200.00'),findsOneWidget);expect(find.text('900.00'),findsOneWidget);
    expect(find.text('100.00'),findsOneWidget);expect(find.text('1100.00'),findsOneWidget);
    expect(find.text('00000000-0000-4000-8000-000000000009'),findsOneWidget);
    expect(find.text('2026-10-06 00:01:02'),findsOneWidget);expect(t.takeException(),isNull);
  });
}
