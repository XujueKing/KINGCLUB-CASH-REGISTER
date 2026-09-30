import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';
import 'package:kingclub_cash_register/src/live/provider_payment_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;

class OriginalAuth extends CheckoutDialogAuth {
  bool fail = false;
  int reads = 0;
  Completer<List<ProviderPayment>>? wait;
  @override
  Future<List<ProviderPayment>> pendingProviderPayments(String channel) async {
    reads++;
    if (fail) throw StateError('TEST_PRIVATE_ERROR');
    return wait == null ? [] : await wait!.future;
  }
}

void main() {
  Future<void> mount(WidgetTester tester, OriginalAuth auth) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProviderPaymentPanel(
              auth: auth,
              orderRef: 'D00000000001',
              totalCents: 100,
              language: UiLanguage.en,
              recoveryOnly: true,
            ),
          ),
        ),
      );

  testWidgets(
    'failed original read provides explicit local retry without collecting',
    (tester) async {
      final auth = OriginalAuth()..fail = true;
      await mount(tester, auth);
      await tester.pumpAndSettle();
      expect(auth.reads, 1);
      expect(find.textContaining('TEST_PRIVATE_ERROR'), findsNothing);
      auth.fail = false;
      await tester.tap(find.text(tr(UiLanguage.en, 'ordersRefresh')));
      await tester.pumpAndSettle();
      expect(auth.reads, 2);
      expect(auth.collections, 0);
      expect(find.text(tr(UiLanguage.en, 'ordersRefresh')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'older local read cannot replace originals after scope invalidation',
    (tester) async {
      final old = Completer<List<ProviderPayment>>();
      final auth = OriginalAuth()..wait = old;
      final original = ProviderPayment.create(
        auth.session,
        'D00000000001',
        'member_balance',
        100,
        accountType: 'platform_cash',
      );
      await mount(tester, auth);
      await tester.pump();
      auth.wait = null;
      auth.notifyListeners();
      await tester.pumpAndSettle();
      old.complete([original]);
      await tester.pumpAndSettle();
      expect(find.textContaining(original.requestId), findsNothing);
      expect(auth.reads, 2);
      expect(auth.collections, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
