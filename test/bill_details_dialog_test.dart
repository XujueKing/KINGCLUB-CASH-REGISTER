import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/bill_details_dialog.dart';
import 'package:kingclub_cash_register/src/live/bill_product_group.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'support/order_fixture.dart';

List<LiveOrder> records() {
  final raw = orderFixture(), data = raw['result'] as Map;
  final paid =
      ((orderFixture()['result'] as Map)['orders'] as List).first as Map;
  paid['orderRef'] = 'D00000000002';
  paid['status'] = 'paid';
  (paid['items'] as List).first['servedQuantity'] = 1;
  (paid['items'] as List).first['remainingQuantity'] = 1;
  (data['orders'] as List).add(paid);
  return OrderSnapshot.parse(
    raw,
    storeRef: 'test-store',
    tableRef: 'test-000',
    sessionRef: 'session-0',
  ).orders;
}

void main() {
  for (final language in UiLanguage.values) {
    testWidgets('original paid and unpaid delivery rows fit ${language.name}', (
      tester,
    ) async {
      final group = groupBillProducts(records()).single;
      BillDetailAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  action = await showDialog<BillDetailAction>(
                    context: context,
                    builder: (_) => BillDetailsDialog(
                      group: group,
                      language: language,
                      canServe: (order, item) => order.status == 'paid',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final key in [
        'bill-detail-D00000000001-unserved',
        'bill-detail-D00000000002-unserved',
        'bill-detail-D00000000002-served',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('bill-add-product')), findsNothing);
      expect(
        find.byKey(const ValueKey('bill-serve-D00000000001')),
        findsNothing,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('bill-refund-D00000000002-served')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('bill-serve-D00000000002')));
      await tester.pumpAndSettle();
      expect(action?.order.reference, 'D00000000002');
      expect(action?.action, 'serve');
      expect(action?.served, false);
      expect(tester.takeException(), isNull);
    });
  }
}
