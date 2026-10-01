import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_dialog.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;
import 'support/order_fixture.dart';
import 'support/table_fixture.dart';

class RealtimeCheckoutAuth extends CheckoutDialogAuth {
  int reads = 0;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    reads++;
    return orderFixture();
  }
}

void main() {
  for (final beforeFirstFrame in [true, false]) {
    testWidgets(
      'store revision preserves original checkout; authority closes it (early=$beforeFirstFrame)',
      (tester) async {
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = RealtimeCheckoutAuth();
        Future<void> show(int revision) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LiveOrdersPanel(
                auth: auth,
                language: UiLanguage.en,
                revision: revision,
                onBack: () {},
                table: LiveTable(
                  (tableFixture()['result'] as Map)['tables'][0]
                      as Map<String, dynamic>,
                ),
              ),
            ),
          ),
        );
        await show(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('table-checkout-open')));
        if (!beforeFirstFrame) await tester.pumpAndSettle();
        await show(1);
        await tester.pumpAndSettle();
        expect(find.byType(TableCheckoutDialog), findsOneWidget);
        final previousReads = auth.reads;
        await show(2);
        await tester.pump(const Duration(milliseconds: 401));
        await tester.pumpAndSettle();
        expect(find.byType(TableCheckoutDialog), findsOneWidget);
        expect(auth.reads, greaterThan(previousReads));
        expect(auth.preparations, 0);
        expect(auth.collections, 0);
        auth.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(TableCheckoutDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
