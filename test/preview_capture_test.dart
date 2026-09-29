// Optional local render evidence; font is supplied by the workstation, not Git.
// flutter test test/preview_capture_test.dart --update-goldens
//   --dart-define=CAPTURE_PREVIEW=true
//   --dart-define=PREVIEW_FONT=C:/Windows/Fonts/msyh.ttc
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/main.dart';

void main() {
  testWidgets('Render workbench, menu and checkout for visual inspection', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fontBytes = ByteData.sublistView(
        await File(const String.fromEnvironment('PREVIEW_FONT')).readAsBytes(),
      );
      for (final name in ['Roboto', 'Ahem']) {
        await (FontLoader(name)..addFont(Future.value(fontBytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('capture'),
        child: CashierApp(preview: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desk-T01')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../artifacts/workbench.png'),
    );
    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('variant-six')));
    await tester.tap(find.text('加入草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-p6')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../artifacts/menu.png'),
    );
    await tester.tap(find.byKey(const ValueKey('checkout')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../artifacts/checkout.png'),
    );
    expect(tester.takeException(), isNull);
  }, skip: !const bool.fromEnvironment('CAPTURE_PREVIEW'));
}
