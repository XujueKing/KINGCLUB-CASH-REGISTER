import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_dialog.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_recovery_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;
import 'table_checkout_command_test.dart' as fixture;
import 'support/lifecycle.dart';

void main() {
  for (final removed in [false, true]) {
    testWidgets(
      'recovery binds original even when local index changed: removed=$removed',
      (tester) async {
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = fixture.command();
        final auth = CheckoutDialogAuth()..saved = original;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TableCheckoutRecoveryPanel(
                auth: auth,
                language: UiLanguage.en,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey(original.requestId)), findsOneWidget);
        if (removed) auth.saved = null;
        await tester.tap(find.text(tr(UiLanguage.en, 'tableCheckoutQuery')));
        await tester.pumpAndSettle();
        final dialog = tester.widget<TableCheckoutDialog>(
          find.byType(TableCheckoutDialog),
        );
        expect(dialog.originalRequestId, original.requestId);
        expect(dialog.sessionRef, original.sessionRef);
        expect(dialog.tableRef, original.tableRef);
        if (removed) {
          expect(find.byType(DropdownButton<String>), findsNothing);
          expect(
            find.text('Could not load the bill. Please retry.'),
            findsOneWidget,
          );
        }
        expect(auth.preparations, 0);
        expect(auth.collections, 0);
        expect(auth.recoveries, 0);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
  testWidgets('background removes original request details', (tester) async {
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    final original = fixture.command();
    final auth = CheckoutDialogAuth()..saved = original;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TableCheckoutRecoveryPanel(
            auth: auth,
            language: UiLanguage.en,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await transitionLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(find.byKey(ValueKey(original.requestId)), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    auth.dispose();
  });
}
