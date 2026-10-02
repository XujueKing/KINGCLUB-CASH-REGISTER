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
  testWidgets(
    'partial refund has a separate returned row and only one unit left to serve',
    (tester) async {
      final data =
          orderFixture()['result']['orders'][0] as Map<String, dynamic>;
      data.addAll({
        'status': 'paid',
        'cashierOrder': true,
        'refunds': [
          {
            'refundRef': '00000000-0000-4000-8000-000000000001',
            'accountType': 'platform_cash',
            'totalCents': 600,
            'principalCents': 600,
            'giftCents': 0,
            'refundedAt': '2026-10-03T00:00:00Z',
          },
        ],
      });
      data['items'][0]['refundedQuantity'] = 1;
      data['items'][0]['remainingQuantity'] = 1;
      final order = LiveOrder(data);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BillDetailsDialog(
              group: groupBillProducts([order]).single,
              language: UiLanguage.zh,
              canServe: (o, i) =>
                  o.refundQuantitiesKnown && i.remainingQuantity! > 0,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('bill-detail-D00000000001-refunded')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bill-detail-D00000000001-unserved')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bill-serve-D00000000001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bill-refund-D00000000001-refunded')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
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
