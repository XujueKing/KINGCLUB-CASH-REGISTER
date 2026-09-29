import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';

import '../strings.dart';
import 'escpos_raster.dart';

// Pixel loops run off the UI isolate on Android. No dart:ui objects cross isolates.
({MonochromeRaster raster, Uint8List pixels}) _preparePreview(
  ({int width, int height, Uint8List rgba}) input,
) {
  final raster = MonochromeRaster.fromStraightRgba(
    width: input.width,
    height: input.height,
    rgba: input.rgba,
  );
  final pixels = Uint8List(input.width * input.height * 4);
  for (var pixel = 0; pixel < input.width * input.height; pixel++) {
    final row = pixel ~/ input.width, column = pixel % input.width;
    final black =
        raster.pixels[row * raster.rowBytes + column ~/ 8] &
            (0x80 >> (column % 8)) !=
        0;
    final shade = black ? 0 : 255;
    pixels[pixel * 4] = shade;
    pixels[pixel * 4 + 1] = shade;
    pixels[pixel * 4 + 2] = shade;
    pixels[pixel * 4 + 3] = 255;
  }
  return (raster: raster, pixels: pixels);
}

class RenderedTestReceipt {
  RenderedTestReceipt(this.raster, Uint8List png)
    : png = Uint8List.fromList(png).asUnmodifiableView();
  final MonochromeRaster raster;

  /// Preview of the exact thresholded dots, not the antialiased source image.
  final Uint8List png;
}

/// Fixed non-transaction test content only. No customer/order/network inputs.
/// Width is explicitly supplied in dots; 80mm paper does not establish dot width.
Future<RenderedTestReceipt> renderTestReceipt({
  required UiLanguage language,
  required int widthDots,
  String? fontFamily,
}) async {
  if (widthDots < 192 || widthDots > 576 || widthDots % 8 != 0) {
    throw const FormatException('TEST_RECEIPT_WIDTH_INVALID');
  }
  final lines = [
    'KINGCLUB POS',
    'TEST ONLY - NOT A RECEIPT',
    tr(language, 'printerTestTitle'),
    tr(language, 'printerTestBody'),
    '${tr(language, 'printerTestDotWidth')}: $widthDots',
    tr(language, 'printerTestGlyphs'),
    '0123456789  ABCDEFG  abcdefg',
    tr(language, 'printerTestNoTransaction'),
    'TEST ONLY - NOT A RECEIPT',
  ];
  final painters = <TextPainter>[];
  ui.Picture? picture;
  ui.Image? source;
  ui.Image? preview;
  try {
    var height = 32.0;
    for (var index = 0; index < lines.length; index++) {
      final painter = TextPainter(
        text: TextSpan(
          text: lines[index],
          style: TextStyle(
            fontFamily: fontFamily,
            fontFamilyFallback: const ['Noto Sans Thai', 'Noto Sans CJK SC'],
            fontSize: index == 0 ? 30 : 24,
            height: 1.4,
            fontWeight: index < 3 ? FontWeight.w700 : FontWeight.w400,
            color: const ui.Color(0xff000000),
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: widthDots - 32);
      painters.add(painter);
      height += painter.height + 12;
    }
    final rows = height.ceil();
    if (rows > 4096) throw const FormatException('TEST_RECEIPT_TOO_TALL');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    var y = 16.0;
    for (final painter in painters) {
      painter.paint(canvas, ui.Offset(16, y));
      y += painter.height + 12;
    }
    // Width calibration rule; physical dot pitch/printhead width is still unverified.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, rows - 8.0, widthDots.toDouble(), 2),
      ui.Paint()..color = const ui.Color(0xff000000),
    );
    picture = recorder.endRecording();
    source = await picture.toImage(widthDots, rows);
    final bytes = await source.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) throw const FormatException('TEST_RECEIPT_IMAGE_FAILED');
    final prepared = await compute(_preparePreview, (
      width: widthDots,
      height: rows,
      rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    ), debugLabel: 'test-receipt-raster');
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      prepared.pixels,
      widthDots,
      rows,
      ui.PixelFormat.rgba8888,
      decoded.complete,
    );
    preview = await decoded.future;
    final png = await preview.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('TEST_RECEIPT_PNG_FAILED');
    return RenderedTestReceipt(
      prepared.raster,
      Uint8List.fromList(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      ),
    );
  } finally {
    preview?.dispose();
    source?.dispose();
    picture?.dispose();
    for (final painter in painters) {
      painter.dispose();
    }
  }
}
