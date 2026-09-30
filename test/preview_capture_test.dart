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
  testWidgets('Render the single product login for visual inspection', (
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
        child: CashierApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, skip: !const bool.fromEnvironment('CAPTURE_PREVIEW'));
}
