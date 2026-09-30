import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  testWidgets('missing employee session cannot offer refund submission', (
    tester,
  ) async {
    final auth = StaffAuthController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BalanceRefundDialog(
            auth: auth,
            orderRef: 'D00000000001',
            language: UiLanguage.zh,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(tr(UiLanguage.zh, 'refundUnavailable')), findsOneWidget);
    expect(find.text(tr(UiLanguage.zh, 'refundSubmit')), findsNothing);
    expect(find.text(tr(UiLanguage.zh, 'refundRetry')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });
  test('all refund interaction labels have four nonempty translations', () {
    for (final key in [
      'refundTitle',
      'refundNotice',
      'refundReason',
      'refundDispositionReason',
      'refundIssued',
      'refundReturnQuantity',
      'refundPhysical',
      'refundConsent',
      'refundSubmit',
      'refundQuery',
      'refundRetry',
      'refundReload',
      'refundDone',
      'refundUnavailable',
      'refundDecisionsRequired',
      'refundUnknown',
      'refundNotObserved',
    ]) {
      expect(copy[key]!.split('|'), hasLength(4));
      for (final language in UiLanguage.values) {
        expect(tr(language, key).trim(), isNotEmpty);
      }
    }
  });
}
