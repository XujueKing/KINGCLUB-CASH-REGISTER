import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/main.dart';
import 'package:kingclub_cash_register/src/workbench_page.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/table_fixture.dart';

import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'Occupied and empty cards align with all actions in four languages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = TableAuth(
        permissions: [
          'workbench.read',
          'table.open',
          'table.clear',
          'orders.create',
          'orders.read',
        ],
      );
      addTearDown(auth.dispose);
      final fixture = tableFixture(count: 2);
      final tables = fixture['result']['tables'] as List;
      tables[1]['session'] = null;
      tables[0]['session']['refundedOrders'] = 1;
      tables[0]['session']['refundedCents'] = 100;
      auth.reply = fixture;
      for (final size in [const Size(1366, 768), const Size(1024, 600)]) {
        tester.view.physicalSize = size;
        for (final language in UiLanguage.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LiveTablesPanel(
                  key: ValueKey('$size-$language'),
                  auth: auth,
                  language: language,
                  enableRealtime: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final occupied = tester.getRect(
            find.byKey(const ValueKey('live-table-test-000')),
          );
          final empty = tester.getRect(
            find.byKey(const ValueKey('live-table-test-001')),
          );
          expect(occupied.height, empty.height);
          expect(occupied.top, empty.top);
          expect(tester.takeException(), isNull, reason: '$size $language');
          await tester.tap(find.byKey(const ValueKey('table-tools')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('order-recovery-open')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(tr(language, 'staffCancelSelection')));
          await tester.pumpAndSettle();
        }
      }
    },
  );
  testWidgets(
    'Only authenticated product entry; no demo, endpoint or store input',
    (tester) async {
      await tester.pumpWidget(const CashierApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('staff-login')), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('T01'), findsNothing);
      expect(find.byKey(const ValueKey('staff-endpoint')), findsNothing);
      expect(find.byKey(const ValueKey('staff-store')), findsNothing);
    },
  );
  testWidgets(
    'Original branded shell displays server tables and unavailable modules honestly',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = TableAuth();
      addTearDown(auth.dispose);
      var language = UiLanguage.zh;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => WorkbenchPage(
              auth: auth,
              language: language,
              onLanguage: (value) => setState(() => language = value),
              onLogout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('kingclub-logo')), findsOneWidget);
      expect(find.text('Test table 0'), findsOneWidget);
      expect(find.text('T01'), findsNothing);
      for (final label in ['English', '繁體中文', 'ไทย', '简体中文']) {
        await tester.tap(find.byKey(const ValueKey('staff-language')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      for (final index in [2, 3, 4, 5, 0]) {
        await tester.tap(find.byKey(ValueKey('nav-$index')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('Test table 0'), findsOneWidget);
    },
  );
}
