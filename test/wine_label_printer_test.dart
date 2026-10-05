import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:kingclub_cash_register/src/hardware/wine_label_printer.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_print_identity.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';

void main() {
  testWidgets(
    'fixed width label raster has readable content, QR and final cut only',
    (tester) async {
      final label = WineLabel({
        'itemRef': '22222222-2222-4222-8222-222222222222',
        'bottleCode': 'KC:W:' + 'B' * 32,
        'name': '芝华士12年',
        'specification': '750ML',
        'nickname': '测试会员',
        'memberNumber': 'KM0000000001',
        'locationCode': 'A6-4',
        'remainingPercent': 50,
        'expiresAt': '2026-11-04T00:00:00Z',
      });
      await tester.runAsync(() async {
        final fontPath = Platform.environment['WINE_LABEL_FONT'];
        if (fontPath != null) {
          final loader = FontLoader('WinePreview');
          loader.addFont(
            File(fontPath)
                .readAsBytes()
                .then((bytes) => ByteData.sublistView(bytes)),
          );
          await loader.load();
        }
        final raster = await label.render(
          fontFamily: fontPath == null ? null : 'WinePreview',
        );
        expect(raster.width, 576);
        expect(raster.height, 216);
        expect(raster.pixels.any((b) => b != 0), isTrue);
        expect(
          encodeGsV0(
            raster,
            cutAtEnd: true,
          ).sublist(encodeGsV0(raster, cutAtEnd: true).length - 4),
          [0x1d, 0x56, 66, 0],
        );
        // Optional standalone test artifact, never real member data.
        final output = Platform.environment['WINE_LABEL_PREVIEW'];
        if (output != null) {
          final pixels = Uint8List(576 * 216 * 4);
          for (var y = 0; y < 216; y++)
            for (var x = 0; x < 576; x++) {
              final black =
                  (raster.pixels[y * raster.rowBytes + x ~/ 8] &
                      (0x80 >> (x % 8))) !=
                  0;
              final i = (y * 576 + x) * 4;
              pixels[i] = pixels[i + 1] = pixels[i + 2] = black ? 0 : 255;
              pixels[i + 3] = 255;
            }
          final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
          final descriptor = ui.ImageDescriptor.raw(
            buffer,
            width: 576,
            height: 216,
            pixelFormat: ui.PixelFormat.rgba8888,
          );
          final codec = await descriptor.instantiateCodec();
          final frame = await codec.getNextFrame();
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(output).writeAsBytes(png!.buffer.asUint8List());
          frame.image.dispose();
          codec.dispose();
          descriptor.dispose();
          buffer.dispose();
        }
      });
    },
  );
  test('label print fence differs from a table receipt', () {
    final label = ReceiptPrintIdentity.wineLabel(
      base: 'https://test.invalid/api',
      storeRef: 'test-store',
      itemRef: '22222222-2222-4222-8222-222222222222',
    );
    final table = ReceiptPrintIdentity.forTable(
      base: 'https://test.invalid/api',
      storeRef: 'test-store',
      checkoutRef: '22222222-2222-4222-8222-222222222222',
    );
    expect(label.canonical, isNot(table.canonical));
  });
}
