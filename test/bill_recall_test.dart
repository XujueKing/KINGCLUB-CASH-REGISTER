import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/serving_command.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'bill_serving_dialog_test.dart' show BillServingAuth;
import 'serving_command_test.dart' as commands;
import 'staff_session_test.dart' as account;

class RecallAuth extends BillServingAuth {
  RecallAuth() {
    status = 'paid';
  }
  int served = 2, epoch = 0;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final raw = await super.readOrders(
      tableRef: tableRef,
      sessionRef: sessionRef,
      afterOrder: afterOrder,
    ) as Map;
    final line =
        ((raw['result']['orders'] as List).first['items'] as List).first as Map;
    line['servedQuantity'] = served;
    line['remainingQuantity'] = 2 - served;
    line['servingEpoch'] = epoch;
    return raw;
  }

  @override
  Future<ServingResult> confirmServing({
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int quantity,
    required int expectedServedQuantity,
    required int targetServedQuantity,
    int? expectedServingEpoch,
    required bool confirmed,
  }) async {
    expect(expectedServedQuantity, served);
    expect(expectedServingEpoch, epoch);
    expect(targetServedQuantity, served - 1);
    final c = PendingServing.prepare(
      identity: session,
      tableRef: tableRef,
      sessionRef: sessionRef,
      orderRef: orderRef,
      productRef: productRef,
      quantity: quantity,
      expectedServedQuantity: expectedServedQuantity,
      targetServedQuantity: targetServedQuantity,
      expectedServingEpoch: expectedServingEpoch,
      now: account.now,
      confirmed: confirmed,
    );
    writes++;
    served--;
    epoch++;
    return ServingResult.parse(commands.result(c), c);
  }
}

void main() {
  for (final language in UiLanguage.values) {
    testWidgets('recall quantity and separate return choice ${language.name}', (
      tester,
    ) async {
      final auth = RecallAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TableBillPanel(
                auth: auth,
                language: language,
                tableRef: 'test-000',
                sessionRef: 'H00000000001',
                revision: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bill-group-CNY-test-product')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bill-recall-D00000000001')));
      await tester.pumpAndSettle();
      expect(find.text(tr(language, 'billRecallReturn')), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, tr(language, 'billRecallReturn')),
            )
            .enabled,
        false,
      );
      await tester.tap(find.byKey(const ValueKey('bill-recall-wait')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('quantity-plus')))
            .onPressed,
        isNull,
      );
      if (tester
              .widget<IconButton>(find.byKey(const ValueKey('quantity-minus')))
              .onPressed !=
          null) {
        await tester.tap(find.byKey(const ValueKey('quantity-minus')));
      }
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bill-serving-submit')));
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(auth.served, 1);
      expect(auth.epoch, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
