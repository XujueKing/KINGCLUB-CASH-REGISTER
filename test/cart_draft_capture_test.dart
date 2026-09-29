// Optional synthetic UI render only; never real business or device acceptance.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_cart_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'cart_draft_ui_test.dart' as d;
import 'live_cart_panel_test.dart' as ui;
import 'order_context_test.dart' as m;

void main() {
  testWidgets('Render saved cart at compact landscape with real local font', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bytes = ByteData.sublistView(
        await File(const String.fromEnvironment('PREVIEW_FONT')).readAsBytes(),
      );
      for (final family in ['Roboto', 'Ahem']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final language in [UiLanguage.zh, UiLanguage.en]) {
      final auth = d.DraftAuth()..drafts = [d.seed()];
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('cart-capture'),
            child: Scaffold(
              body: LiveCartPanel(
                auth: auth,
                language: language,
                orderContext: m.parse(m.contextData()),
                memberRef: 'member-000',
                onBack: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await ui.tap(tester, 'cart-draft-restore');
      await ui.tap(tester, 'cart-plus-p001');
      await expectLater(
        find.byKey(const ValueKey('cart-capture')),
        matchesGoldenFile('../artifacts/cart-draft-${language.name}.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_CART_DRAFT'));
}
