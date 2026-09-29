import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';
import 'support/table_fixture.dart';

class OrdersAuth extends TableAuth {
  Completer<Object?>? ordersGate;
  int reads = 0;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    expect(tableRef, 'test-000');
    expect(sessionRef, 'session-0');
    reads++;
    return ordersGate == null ? orderFixture() : ordersGate!.future;
  }
}

void main() {
  Future<void> show(
    WidgetTester tester,
    OrdersAuth auth, {
    int revision = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveOrdersPanel(
            auth: auth,
            language: UiLanguage.en,
            revision: revision,
            onBack: () {},
            table: LiveTable(
              ((tableFixture()['result'] as Map)['tables'] as List).first
                  as Map<String, dynamic>,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'shows server order and clears details when employee identity changes',
    (tester) async {
      final auth = OrdersAuth();
      await show(tester, auth);
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(find.textContaining('Pending payment'), findsOneWidget);
      auth.notifyListeners();
      await tester.pump();
      expect(find.textContaining('Test product'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'discards background late replies and reloads on resume and realtime change',
    (tester) async {
      final auth = OrdersAuth()..ordersGate = Completer<Object?>();
      await show(tester, auth);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      auth.ordersGate!.complete(orderFixture());
      await tester.pump();
      expect(find.textContaining('Test product'), findsNothing);
      auth.ordersGate = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      final reads = auth.reads;
      await show(tester, auth, revision: 1);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(auth.reads, reads + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
