import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/raster_preview.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_raster_preview_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'receipt_document_test.dart' show document, parse;

void main() {
  testWidgets('width change immediately drops old image; dispose ignores late bitmap', (tester) async {
    tester.view.physicalSize = const Size(1366, 768); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final source = parse(document());
    final plan = ReceiptRasterPlan.create(source, language: UiLanguage.en, widthDots: 576);
    final fixture = (await tester.runAsync(() => plan.renderPage(0)))!;
    final jobs = <Completer<RasterPreview>>[], widths = <int>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReceiptRasterPreviewPanel(
      document: source, language: UiLanguage.en, render: (plan, page) {
        widths.add(plan.widthDots); final job = Completer<RasterPreview>(); jobs.add(job); return job.future;
      },
    ))));
    jobs[0].complete(fixture); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-raster-image')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receipt-raster-width'))); await tester.pumpAndSettle();
    await tester.tap(find.text('512').last); await tester.pump();
    expect(find.byKey(const ValueKey('receipt-raster-image')), findsNothing);
    expect(widths, [576, 512]);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    jobs[1].complete(fixture); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('background invalidates in-flight page and resume does not recreate stale content', (tester) async {
    final source = parse(document());
    final fixture = (await tester.runAsync(() => ReceiptRasterPlan.create(source,
      language: UiLanguage.en, widthDots: 576).renderPage(0)))!;
    final job = Completer<RasterPreview>(); var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReceiptRasterPreviewPanel(
      document: source, language: UiLanguage.en, render: (_, _) {calls++; return job.future;},
    ))));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await tester.pump();
    job.complete(fixture); await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pump();
    expect(find.byKey(const ValueKey('receipt-raster-image')), findsNothing);
    expect(calls, 1); expect(tester.takeException(), isNull);
  });
}
