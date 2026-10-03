import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';

class PriceAuth extends TableAuth {
  PriceAuth()
    : super(
        permissions: const [
          'workbench.read',
          'orders.read',
          'orders.create',
          'orders.serve',
        ],
      );
  List<Map<String, Object>>? changed;
  int? price;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final raw = orderFixture(), data = raw['result'] as Map;
    data['tableRef'] = tableRef;
    data['session']['sessionRef'] = sessionRef;
    final original = data['orders'][0];
    data['orders'] = [
      for (var i = 1; i <= 3; i++)
        {
          ...jsonDecode(jsonEncode(original)) as Map<String, dynamic>,
          'orderRef': 'D0000000000$i',
          'status': i == 2 ? 'paid' : 'pending',
        },
    ];
    data.remove('sessionSummary');
    return raw;
  }

  @override
  Future<String> repriceUnpaidItems({
    required String tableRef,
    required String sessionRef,
    required String productRef,
    required int unitPriceCents,
    String? expenseOwnerUserAccount,
    required List<Map<String, Object>> items,
  }) async {
    changed = items;
    price = unitPriceCents;
    return 'price-test';
  }
}

void main() {
  for (final language in UiLanguage.values) {
    testWidgets(
      'card edits every unpaid batch and preserves paid units ${language.name}',
      (tester) async {
        final auth = PriceAuth();
        tester.view.physicalSize = const Size(1366, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TableBillPanel(
                auth: auth,
                language: language,
                tableRef: 'test-000',
                sessionRef: 'H00000000001',
                revision: 0,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('bill-group-CNY-test-product')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('item-price-input')), findsOneWidget);
        expect(find.text('¥ 6.00 × 4 = ¥ 24.00'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('item-price-input')),
          '3.00',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('item-price-save')));
        await tester.pumpAndSettle();
        expect(auth.price, 300);
        expect(auth.changed!.map((row) => row['orderRef']), [
          'D00000000001',
          'D00000000003',
        ]);
        expect(auth.changed!.map((row) => row['expectedQuantity']), [2, 2]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
