import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/private_raster_image.dart';
import 'package:kingclub_cash_register/src/hardware/raster_preview.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'receipt_document_test.dart' show document, parse;

void main() {
  Future<RasterPreview> fixture(WidgetTester tester) async => (await tester.runAsync(() =>
    ReceiptRasterPlan.create(parse(document()), language: UiLanguage.en, widthDots: 576).renderPage(0)))!;
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    expect(ready(), isTrue);
  }
  Widget view(RasterPreview preview) => MaterialApp(home: PrivateRasterImage(
    preview: preview, label: 'TEST_PRIVATE_RECEIPT', failureLabel: 'TEST_DECODE_FAILED'));
  testWidgets('decode bypasses shared cache and owned image is disposed on removal', (tester) async {
    final preview = await fixture(tester), cache = PaintingBinding.instance.imageCache;
    final before = (cache.currentSize, cache.currentSizeBytes, cache.liveImageCount, cache.pendingImageCount);
    await tester.pumpWidget(view(preview));
    await waitFor(tester, () => tester.widget<RawImage>(find.byType(RawImage)).image != null);
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((cache.currentSize, cache.currentSizeBytes, cache.liveImageCount, cache.pendingImageCount), before);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(image.debugDisposed, isTrue);
  });
  testWidgets('replacement clears old image immediately and disposes it', (tester) async {
    final preview = await fixture(tester);
    await tester.pumpWidget(view(preview));
    await waitFor(tester, () => tester.widget<RawImage>(find.byType(RawImage)).image != null);
    final old = tester.widget<RawImage>(find.byType(RawImage)).image!;
    await tester.pumpWidget(view(RasterPreview(preview.raster, Uint8List.fromList([1,2,3]))));
    expect(old.debugDisposed, isTrue);
    await waitFor(tester, () => find.text('TEST_DECODE_FAILED').evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsNothing);
  });
  testWidgets('dispose during decode never reinstates financial content', (tester) async {
    final preview = await fixture(tester);
    await tester.pumpWidget(view(preview));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.byType(RawImage), findsNothing); expect(tester.takeException(), isNull);
  });
}
