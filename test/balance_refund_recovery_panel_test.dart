import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_command.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_context.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_dialog.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_recovery_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'balance_refund_command_test.dart' as c;

class RecoveryAuth extends StaffAuthController {
  List<PendingBalanceRefund> entries = [];
  bool fail = false;
  int contextReads = 0;
  @override
  Future<List<PendingBalanceRefund>> pendingBalanceRefunds() async {
    if (fail) throw StateError('TEST_STORAGE');
    return entries;
  }

  @override
  Future<BalanceRefundContext> balanceRefundContext(String orderRef) async {
    contextReads++;
    throw StateError('Recovery must not create a new refund form');
  }
}

void main() {
  testWidgets(
    'recovery-only dialog never reads a new refund context when journal is empty',
    (tester) async {
      final auth = RecoveryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BalanceRefundDialog(
              auth: auth,
              orderRef: 'D00000000001',
              language: UiLanguage.zh,
              recoveryOnly: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.contextReads, 0);
      expect(
        find.text(tr(UiLanguage.zh, 'refundRecoveryEmpty')),
        findsOneWidget,
      );
      expect(find.text(tr(UiLanguage.zh, 'refundSubmit')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
    },
  );
  testWidgets(
    'global recovery opens saved original without needing any table snapshot',
    (tester) async {
      final auth = RecoveryAuth()..entries = [c.command()];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BalanceRefundRecoveryPanel(
              auth: auth,
              language: UiLanguage.zh,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(auth.entries.single.refundRef), findsOneWidget);
      await tester.tap(find.text(tr(UiLanguage.zh, 'refundQuery')));
      await tester.pumpAndSettle();
      expect(find.byType(BalanceRefundDialog), findsOneWidget);
      expect(find.text(tr(UiLanguage.zh, 'refundRetry')), findsOneWidget);
      expect(find.text(tr(UiLanguage.zh, 'refundSubmit')), findsNothing);
      expect(auth.contextReads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
    },
  );
  testWidgets('unreadable journal is not shown as empty or successful', (
    tester,
  ) async {
    final auth = RecoveryAuth()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BalanceRefundRecoveryPanel(
            auth: auth,
            language: UiLanguage.zh,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(tr(UiLanguage.zh, 'refundUnavailable')), findsOneWidget);
    expect(find.text(tr(UiLanguage.zh, 'refundRecoveryEmpty')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });
}
