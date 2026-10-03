import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/bill_product_card.dart';
import 'package:kingclub_cash_register/src/live/live_cart_panel.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_cart_panel_test.dart' show CartAuth, tap;
import 'order_context_test.dart' as context_fixture;
import 'staff_session_test.dart' as staff;
import 'order_command_test.dart' as command_fixture;
import 'support/order_fixture.dart';

class RealtimeBillAuth extends CartAuth {
  final StaffSession identity = staff.session({
    ...staff.response(),
    'permissions': ['workbench.read', 'orders.read', 'orders.create'],
  });
  @override
  StaffSession get session => identity;
  bool pushed = false;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    Map<String, dynamic> order(String ref, int price, String status) {
      final result = orderFixture()['result'] as Map;
      final data = (result['orders'] as List).single as Map<String, dynamic>;
      data['orderRef'] = ref;
      data['status'] = status;
      data['totalCents'] = price;
      final item = (data['items'] as List).single as Map;
      item['productRef'] = 'p001';
      item['quantity'] = 1;
      item['remainingQuantity'] = 1;
      item['priceCents'] = price;
      item['subtotalCents'] = price;
      return data;
    }

    final raw = orderFixture(), result = raw['result'] as Map;
    result['tableRef'] = tableRef;
    result['session']['sessionRef'] = sessionRef;
    result['orders'] = [
      order('D00000000001', 600, 'paid'),
      if (pushed) order('D00000000002', priceCents, 'pending'),
    ];
    return raw;
  }
}

void main() {
  testWidgets(
    'server push before submit receipt neither duplicates quantity nor loses original price',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = RealtimeBillAuth()
        ..submitGate = Completer<OrderRequestResult>();
      final revision = ValueNotifier(0);
      final orderContext = context_fixture.parse(context_fixture.contextData());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: revision,
              builder: (_, value, _) => LiveCartPanel(
                auth: auth,
                language: UiLanguage.en,
                orderContext: orderContext,
                memberRef: 'member-000',
                onBack: () {},
                revision: value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'catalog-add-p001');
      expect(find.byType(BillProductCard), findsOneWidget);
      expect(
        tester.widget<BillProductCard>(find.byType(BillProductCard)).quantity,
        2,
      );
      expect(find.text('Paid 1 / Unpaid 1'), findsOneWidget);
      await tap(tester, 'cart-minus-p001');
      expect(
        tester.widget<BillProductCard>(find.byType(BillProductCard)).quantity,
        1,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('cart-minus-p001')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'cart-minus-p001');
      expect(find.byType(AlertDialog), findsNothing);
      await tap(tester, 'cart-plus-p001');
      expect(find.byType(AlertDialog), findsNothing);
      await tap(tester, 'cart-plus-p001');
      await tap(tester, 'cart-plus-p001');
      expect(
        tester.widget<BillProductCard>(find.byType(BillProductCard)).quantity,
        4,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('cart-plus-p001')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'cart-minus-p001');
      await tap(tester, 'cart-minus-p001');
      await tester.tap(find.byKey(const ValueKey('cart-submit')));
      await tester.pump(const Duration(milliseconds: 300));
      auth.pushed = true;
      revision.value++;
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(BillProductCard), findsOneWidget);
      final card = tester.widget<BillProductCard>(find.byType(BillProductCard));
      expect(card.quantity, 2);
      expect(card.totalCents, 600 + auth.priceCents);
      expect(auth.submits, 1);
      final command = command_fixture.command();
      auth.submitGate!.complete(
        OrderRequestResult.parse(
          {'result': command_fixture.receipt(command.params)},
          command,
          submission: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BillProductCard), findsOneWidget);
      expect(
        tester.widget<BillProductCard>(find.byType(BillProductCard)).quantity,
        2,
      );
      expect(auth.submits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      auth.dispose();
    },
  );
}
