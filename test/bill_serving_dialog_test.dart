import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/live_serving_recovery_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'serving_ui_test.dart' show ServingAuth;
import 'staff_session_test.dart' as account;

import 'package:kingclub_cash_register/src/auth/staff_session.dart';

class BillServingAuth extends ServingAuth {
  final identity = account.session({
    ...account.response(),
    'permissions': ['workbench.read', 'orders.read', 'orders.serve'],
  });
  @override
  StaffSession get session => identity;
}

void main() {
  Widget page(ServingAuth auth, {int revision = 0}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TableBillPanel(
          auth: auth,
          language: UiLanguage.en,
          tableRef: 'test-000',
          sessionRef: 'H00000000001',
          revision: revision,
        ),
      ),
    ),
  );
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('bill-group-CNY-test-product')));
    await tester.pumpAndSettle();
  }

  for (final timing in ['prepay', 'postpay']) {
    testWidgets('bill serving eligibility for unpaid $timing order', (
      tester,
    ) async {
      final auth = BillServingAuth()..timing = timing;
      await tester.pumpWidget(page(auth));
      await tester.pumpAndSettle();
      await open(tester);
      expect(
        find.byKey(const ValueKey('bill-serve-product')),
        timing == 'postpay' ? findsOneWidget : findsNothing,
      );
      expect(auth.writes, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
  testWidgets('paid card serves bounded quantity through existing command', (
    tester,
  ) async {
    final auth = BillServingAuth()
      ..timing = 'prepay'
      ..status = 'paid';
    await tester.pumpWidget(page(auth));
    await tester.pumpAndSettle();
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('bill-serve-product')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bill-serving-quantity')),
      '3',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('bill-serving-submit')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('bill-serving-quantity')),
      '1',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bill-serving-submit')));
    await tester.pumpAndSettle();
    expect(auth.writes, 1);
    expect(auth.pending, isEmpty);
    expect(find.byKey(const ValueKey('bill-serving-submit')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'ambiguous serving opens original recovery without second write',
    (tester) async {
      final auth = BillServingAuth()..failServing = true;
      await tester.pumpWidget(page(auth));
      await tester.pumpAndSettle();
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('bill-serve-product')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bill-serving-submit')));
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(auth.pending, hasLength(1));
      expect(find.byType(LiveServingRecoveryPanel), findsOneWidget);
      expect(auth.retries, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('bill update invalidates an unsubmitted delivery confirmation', (
    tester,
  ) async {
    final auth = BillServingAuth();
    await tester.pumpWidget(page(auth));
    await tester.pumpAndSettle();
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('bill-serve-product')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(auth, revision: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bill-serving-submit')));
    await tester.pumpAndSettle();
    expect(auth.writes, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
