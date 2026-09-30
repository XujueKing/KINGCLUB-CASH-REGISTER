import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/main.dart';
import 'package:kingclub_cash_register/src/workbench_page.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
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
