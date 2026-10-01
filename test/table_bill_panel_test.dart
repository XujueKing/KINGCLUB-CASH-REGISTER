import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';

class BillAuth extends TableAuth {
  BillAuth()
    : super(
        permissions: const ['workbench.read', 'orders.read', 'payment.cash'],
      );
  Completer<Object?>? ordersGate;
  bool cancelled = false;
  bool failRead = false;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    if (failRead) throw StateError('read failed');
    if (ordersGate != null) return ordersGate!.future;
    final raw = orderFixture(), data = raw['result'] as Map;
    (data['orders'] as List).first['status'] = cancelled
        ? 'expired'
        : 'pending';
    data['sessionSummary'] = {
      'currency': 'CNY',
      'paid': {'orderCount': 0, 'totalCents': 0},
      'pending': {
        'orderCount': cancelled ? 0 : 1,
        'totalCents': cancelled ? 0 : 1200,
      },
      'expired': {
        'orderCount': cancelled ? 1 : 0,
        'totalCents': cancelled ? 1200 : 0,
      },
    };
    return raw;
  }
}

void main() {
  Widget page(BillAuth auth, int revision, {bool checkoutAllowed = true}) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TableBillPanel(
              auth: auth,
              language: UiLanguage.en,
              tableRef: 'test-000',
              sessionRef: 'session-0',
              revision: revision,
              checkoutAllowed: checkoutAllowed,
            ),
          ),
        ),
      );
  testWidgets(
    'unsent cart prevents checkout; failed refresh keeps lines but disables payment',
    (tester) async {
      final auth = BillAuth();
      final checkout = find.byKey(const ValueKey('table-bill-checkout'));
      await tester.pumpWidget(page(auth, 0, checkoutAllowed: false));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(checkout).onPressed, isNotNull);
      auth.failRead = true;
      await tester.pumpWidget(page(auth, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'revision updates the table bill and removes cancelled items from due total',
    (tester) async {
      final auth = BillAuth();
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(find.text('Unpaid  CNY 12.00'), findsOneWidget);
      auth.cancelled = true;
      await tester.pumpWidget(page(auth, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsNothing);
      expect(find.text('Unpaid  CNY 0.00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('late read cannot reveal bill after backgrounding', (
    tester,
  ) async {
    final auth = BillAuth()..ordersGate = Completer<Object?>();
    await tester.pumpWidget(page(auth, 0));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    auth.ordersGate!.complete(orderFixture());
    await tester.pumpAndSettle();
    expect(find.textContaining('Test product'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
