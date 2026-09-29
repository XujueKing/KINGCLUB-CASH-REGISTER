import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/test_receipt_renderer.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  for (final language in UiLanguage.values) {
    testWidgets(
      'non-transaction test rendering and exact monochrome preview ${language.name}',
      (tester) async {
        await tester.runAsync(() async {
          for (final width in [192, 512, 576]) {
            final result = await renderTestReceipt(
              language: language,
              widthDots: width,
            );
            expect(result.raster.width, width);
            expect(result.raster.height, inInclusiveRange(1, 4096));
            expect(result.raster.pixels.any((b) => b != 0), true);
            final codec = await ui.instantiateImageCodec(result.png);
            final frame = await codec.getNextFrame();
            try {
              expect(frame.image.width, width);
              expect(frame.image.height, result.raster.height);
              final data = (await frame.image.toByteData(
                format: ui.ImageByteFormat.rawStraightRgba,
              ))!;
              for (var y = 0; y < result.raster.height; y++) {
                for (var x = 0; x < width; x++) {
                  final black =
                      result.raster.pixels[y * result.raster.rowBytes +
                              x ~/ 8] &
                          (128 >> (x % 8)) !=
                      0;
                  final index = (y * width + x) * 4;
                  final expected = black ? 0 : 255;
                  if (data.getUint8(index) != expected ||
                      data.getUint8(index + 1) != expected ||
                      data.getUint8(index + 2) != expected ||
                      data.getUint8(index + 3) != 255) {
                    fail('Preview differs from wire raster at $x/$y');
                  }
                }
              }
            } finally {
              frame.image.dispose();
              codec.dispose();
            }
          }
        });
      },
    );
  }

  test('unsupported layout widths are rejected', () async {
    for (final width in [0, 191, 193, 577, 640]) {
      await expectLater(
        renderTestReceipt(language: UiLanguage.zh, widthDots: width),
        throwsFormatException,
      );
    }
  });

  testWidgets('optional actual-font four-language raster previews', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final pair in [
        ['ReceiptCjk', const String.fromEnvironment('RECEIPT_CJK_FONT')],
        ['ReceiptThai', const String.fromEnvironment('RECEIPT_THAI_FONT')],
      ]) {
        final bytes = ByteData.sublistView(await File(pair[1]).readAsBytes());
        await (FontLoader(pair[0])..addFont(Future.value(bytes))).load();
      }
    });
    for (final language in UiLanguage.values) {
      final result = await tester.runAsync(
        () => renderTestReceipt(
          language: language,
          widthDots: 576,
          fontFamily: language == UiLanguage.th ? 'ReceiptThai' : 'ReceiptCjk',
        ),
      );
      await tester.runAsync(
        () => expectLater(
          result!.png,
          matchesGoldenFile('../artifacts/test-receipt-${language.name}.png'),
        ),
      );
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_TEST_RECEIPT'));
}
