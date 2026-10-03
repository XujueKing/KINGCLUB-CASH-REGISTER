import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';

class ReductionAuth extends TableAuth {
  ReductionAuth()
    : super(permissions: ['workbench.read', 'orders.read', 'orders.create']);
  int quantity = 2, served = 0, calls = 0;
  Completer<void>? reductionGate;
  bool uncertain = false;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final raw = orderFixture(), data = raw['result'] as Map;
    final pending = (data['orders'] as List).first as Map;
    pending['totalCents'] = (quantity == 0 ? 1 : quantity) * 600;
    pending['status'] = quantity == 0 ? 'expired' : 'pending';
    final line = (pending['items'] as List).first as Map;
    line['quantity'] = quantity == 0 ? 1 : quantity;
    line['subtotalCents'] = pending['totalCents'];
    line['servedQuantity'] = served;
    line['remainingQuantity'] = (quantity == 0 ? 1 : quantity) - served;
    final paid =
        ((orderFixture()['result'] as Map)['orders'] as List).first as Map;
    paid['orderRef'] = 'D00000000002';
    paid['status'] = 'paid';
    paid['totalCents'] = 600;
    final paidLine = (paid['items'] as List).first as Map;
    paidLine['quantity'] = 1;
    paidLine['subtotalCents'] = 600;
    paidLine['remainingQuantity'] = 1;
    (data['orders'] as List).add(paid);
    data['sessionSummary'] = {
      'currency': 'CNY',
      'paid': {'orderCount': 1, 'totalCents': 600},
      'pending': {
        'orderCount': quantity > 0 ? 1 : 0,
        'totalCents': quantity * 600,
      },
      'expired': {
        'orderCount': quantity == 0 ? 1 : 0,
        'totalCents': quantity == 0 ? 600 : 0,
      },
    };
    return raw;
  }

  @override
  Future<void> reduceUnpaidItem({
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int expectedQuantity,
    required int expectedServedQuantity,
    int? expectedServingEpoch,
    required int expectedTotalCents,
  }) async {
    calls++;
    expect(orderRef, 'D00000000001');
    expect(expectedQuantity, quantity);
    expect(expectedServedQuantity, served);
    expect(expectedTotalCents, quantity * 600);
    if (reductionGate != null) await reductionGate!.future;
    quantity--;
    if (uncertain) throw StateError('response lost');
  }
}

void main() {
  Future<void> mount(WidgetTester tester, ReductionAuth auth) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TableBillPanel(
            auth: auth,
            language: UiLanguage.zh,
            tableRef: 'test-000',
            sessionRef: 'session-0',
            revision: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder getMinus() => find.byKey(const ValueKey('cart-minus-test-product'));
  testWidgets(
    'submitted unpaid quantities reduce to the paid floor on the same card',
    (tester) async {
      final auth = ReductionAuth();
      await mount(tester, auth);
      expect(find.text('已付款 1 / 未付款 2'), findsOneWidget);
      await tester.tap(getMinus());
      await tester.pumpAndSettle();
      expect(find.text('已付款 1 / 未付款 1'), findsOneWidget);
      await tester.tap(getMinus());
      await tester.pumpAndSettle();
      expect(find.text('已付款 1 / 未付款 0'), findsOneWidget);
      expect(tester.widget<IconButton>(getMinus()).onPressed, isNull);
      expect(auth.calls, 2);
    },
  );
  testWidgets(
    'rapid minus taps use refreshed quantities and stop at paid floor',
    (tester) async {
      final auth = ReductionAuth()..reductionGate = Completer<void>();
      await mount(tester, auth);
      await tester.tap(getMinus());
      await tester.pump();
      expect(tester.widget<IconButton>(getMinus()).onPressed, isNotNull);
      await tester.tap(getMinus());
      await tester.pump();
      expect(auth.calls, 1);
      final gate = auth.reductionGate!;
      auth.reductionGate = null;
      gate.complete();
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(auth.quantity, 0);
      expect(tester.widget<IconButton>(getMinus()).onPressed, isNull);
    },
  );

  testWidgets('delivered unpaid quantities cannot be removed with minus', (
    tester,
  ) async {
    final auth = ReductionAuth()..served = 1;
    await mount(tester, auth);
    await tester.tap(getMinus());
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(getMinus()).onPressed, isNull);
    expect(auth.quantity, 1);
  });
  testWidgets(
    'double taps and a lost response do not decrement a second time',
    (tester) async {
      final auth = ReductionAuth()
        ..reductionGate = Completer<void>()
        ..uncertain = true;
      await mount(tester, auth);
      await tester.tap(getMinus());
      await tester.pump();
      await tester.tap(getMinus());
      await tester.pump();
      expect(auth.calls, 1);
      auth.reductionGate!.complete();
      await tester.pumpAndSettle();
      expect(auth.quantity, 1);
      expect(find.text('已付款 1 / 未付款 1'), findsOneWidget);
    },
  );
}
