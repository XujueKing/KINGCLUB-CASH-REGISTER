import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/raster_preview.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_output_panel.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_raster_preview_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_receipt_document_test.dart' as fixture;

void main() {
  testWidgets(
    'table preview is default-off for output and discards background response',
    (tester) async {
      final source = fixture.parse(fixture.tableReceiptFixture());
      final pixels = (await tester.runAsync(
        () => ReceiptRasterPlan.forTable(
          source,
          language: UiLanguage.en,
          widthDots: 576,
        ).renderPage(0),
      ))!;
      final job = Completer<RasterPreview>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiptRasterPreviewPanel.forTable(
              document: source,
              language: UiLanguage.en,
              sourceBase: 'https://test.invalid',
              render: (plan, page) {
                expect(plan.header, isNot(contains(fixture.checkout)));
                calls++;
                return job.future;
              },
            ),
          ),
        ),
      );
      expect(find.byType(ReceiptOutputPanel), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      job.complete(pixels);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('receipt-raster-image')), findsNothing);
      expect(find.byType(ReceiptOutputPanel), findsNothing);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
