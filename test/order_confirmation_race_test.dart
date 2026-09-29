import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_orders_panel_test.dart' show CashOrdersAuth;
import 'serving_ui_test.dart' show ServingAuth;
import 'support/table_fixture.dart';

void main() {
  for (final serving in [false, true]) {
    for (final change in ['identity', 'background', 'revision']) {
      testWidgets(
        'confirmation first-frame race serving=$serving change=$change',
        (tester) async {
          tester.view.physicalSize = const Size(1366, 768);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final StaffAuthController auth = serving
              ? ServingAuth()
              : CashOrdersAuth();
          final revision = ValueNotifier(0);
          addTearDown(revision.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<int>(
                  valueListenable: revision,
                  builder: (context, value, child) => LiveOrdersPanel(
                    auth: auth,
                    language: UiLanguage.en,
                    revision: value,
                    onBack: () {},
                    table: LiveTable(
                      ((tableFixture()['result'] as Map)['tables'] as List)
                              .first
                          as Map<String, dynamic>,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final button = serving
              ? find.text(tr(UiLanguage.en, 'servingConfirm'))
              : find.byKey(const ValueKey('cash-prepare-D00000000001'));
          await tester.tap(button);
          // Complete journal lookup and push the route, but do not build its first frame.
          await tester.idle();
          if (change == 'identity') {
            auth.notifyListeners();
          } else if (change == 'revision') {
            revision.value++;
          } else {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          }
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(
            find.byKey(const ValueKey('cash-prepare-confirm')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('serving-quantity')), findsNothing);
          expect(
            find.byKey(const ValueKey('serving-confirm-submit')),
            findsNothing,
          );
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            serving
                ? (auth as ServingAuth).writes
                : (auth as CashOrdersAuth).preparations,
            0,
          );
          await tester.pumpWidget(const SizedBox());
          if (change == 'background') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          auth.dispose();
        },
      );
    }
  }
}
