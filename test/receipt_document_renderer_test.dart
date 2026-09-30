import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'receipt_document_test.dart' show document, parse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('long order keeps each item exactly once and repeats scope/status per page', () {
    final raw = document();
    raw['items'] = List.generate(50, (index) => {
      ...document()['items'][0] as Map<String, dynamic>, 'productRef': 'TEST_$index',
      'names': {'zh-CN': '测试项目$index', 'en': 'TEST_ITEM_$index', 'zh-TW': '測試項目$index', 'th': 'ทดสอบ$index'},
    });
    raw['totalCents'] = 5000; raw['netPaidCents'] = 5000;
    raw['tender'] = {'channel': 'cash', 'receivedCents': 5000, 'changeCents': 0};
    final plan = ReceiptRasterPlan.create(parse(raw), language: UiLanguage.en, widthDots: 384);
    expect(plan.pages.length, greaterThan(1)); expect(plan.pages.length, lessThanOrEqualTo(32));
    final all = plan.pages.expand((page) => page).toList();
    for (var index = 0; index < 50; index++) {
      expect(all.where((block) => block.startsWith('TEST_ITEM_$index ·')), hasLength(1));
    }
    expect(plan.header, contains('D00000000001'));
    expect(plan.header, contains(tr(UiLanguage.en, 'order_paid')));
    expect(() => plan.pages[0].clear(), throwsUnsupportedError);
  });
  for (final language in UiLanguage.values) {
    testWidgets('renders $language refund page as exact black-white preview', (tester) async {
      final plan = ReceiptRasterPlan.create(parse(document(channel: 'member_balance', refund: true)),
        language: language, widthDots: 576);
      expect(plan.header, contains(tr(language, 'liveRefunded')));
      final output = (await tester.runAsync(() => plan.renderPage(0)))!;
      expect(output.raster.width, 576); expect(output.raster.height, lessThanOrEqualTo(2048));
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(output.png);
        final frame = await codec.getNextFrame();
        try {
          final bytes = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final pixels = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
          for (var y = 0; y < output.raster.height; y++) {
            for (var x = 0; x < output.raster.width; x++) {
              final black = output.raster.pixels[y * output.raster.rowBytes + x ~/ 8] & (0x80 >> (x % 8)) != 0;
              final offset = (y * output.raster.width + x) * 4, shade = black ? 0 : 255;
              expect(pixels.sublist(offset, offset + 4), [shade, shade, shade, 255]);
            }
          }
        } finally { frame.image.dispose(); codec.dispose(); }
      });
    });
  }
  test('rejects invalid width and page index; no silent cropping', () async {
    final receipt = parse(document());
    for (final width in [0, 191, 193, 584]) {
      expect(() => ReceiptRasterPlan.create(receipt, language: UiLanguage.zh, widthDots: width), throwsFormatException);
    }
    final plan = ReceiptRasterPlan.create(receipt, language: UiLanguage.zh, widthDots: 576);
    await expectLater(plan.renderPage(-1), throwsFormatException);
    await expectLater(plan.renderPage(plan.pages.length), throwsFormatException);
  });
}
