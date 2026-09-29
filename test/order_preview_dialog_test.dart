import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_preview_dialog.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_orders_panel_test.dart' show OrdersAuth;
import 'support/order_fixture.dart';

LiveOrder order(String status) {
  final row =
      ((orderFixture()['result'] as Map)['orders'] as List).first
          as Map<String, dynamic>;
  row['status'] = status;
  return LiveOrder(row);
}

void main() {
  for (final language in UiLanguage.values) {
    for (final status in ['pending', 'paid', 'expired']) {
      testWidgets('single order $status preview in ${language.name}', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1024, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = OrdersAuth();
        await tester.pumpWidget(
          MaterialApp(
            home: OrderPreviewDialog(
              auth: auth,
              order: order(status),
              language: language,
              observedAt: DateTime.utc(2026, 9, 29),
              expiresAt: DateTime.now().add(const Duration(minutes: 10)),
            ),
          ),
        );
        expect(
          find.text(
            '${tr(language, 'orderPreviewStatus')}: ${tr(language, 'order_$status')}',
          ),
          findsOneWidget,
        );
        expect(find.text('2 × CNY 6.00 = CNY 12.00'), findsOneWidget);
        expect(
          find.text('${tr(language, 'orderPreviewTotal')}: CNY 12.00'),
          findsOneWidget,
        );
        expect(find.text(tr(language, 'orderPreviewNotice')), findsNWidgets(2));
        expect(auth.reads, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      });
    }
  }
  for (final reason in ['expiry', 'identity', 'background']) {
    testWidgets('$reason clears preview without re-exposing on resume', (
      tester,
    ) async {
      final auth = OrdersAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: OrderPreviewDialog(
            auth: auth,
            order: order('pending'),
            language: UiLanguage.en,
            observedAt: DateTime.utc(2026, 9, 29),
            expiresAt: DateTime.now().add(const Duration(seconds: 1)),
          ),
        ),
      );
      expect(find.text('D00000000001'), findsOneWidget);
      if (reason == 'expiry') {
        await tester.pump(const Duration(seconds: 2));
      } else if (reason == 'identity') {
        auth.notifyListeners();
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pump();
      expect(find.text('D00000000001'), findsNothing);
      expect(
        find.text(tr(UiLanguage.en, 'orderPreviewExpired')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
