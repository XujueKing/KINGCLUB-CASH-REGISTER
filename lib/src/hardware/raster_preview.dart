import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'escpos_raster.dart';

class RasterPreview {
  RasterPreview(this.raster, Uint8List png) : png = Uint8List.fromList(png).asUnmodifiableView();
  final MonochromeRaster raster;
  final Uint8List png;
}

({MonochromeRaster raster, Uint8List pixels}) _prepare(
  ({int width, int height, Uint8List rgba}) input,
) {
  final raster = MonochromeRaster.fromStraightRgba(width: input.width, height: input.height, rgba: input.rgba);
  final pixels = Uint8List(input.width * input.height * 4);
  for (var index = 0; index < input.width * input.height; index++) {
    final row = index ~/ input.width, column = index % input.width;
    final black = raster.pixels[row * raster.rowBytes + column ~/ 8] & (0x80 >> (column % 8)) != 0;
    final shade = black ? 0 : 255;
    pixels[index * 4] = shade; pixels[index * 4 + 1] = shade; pixels[index * 4 + 2] = shade; pixels[index * 4 + 3] = 255;
  }
  return (raster: raster, pixels: pixels);
}

/// Source remains caller-owned. Preview is re-created from exactly the thresholded
/// printer dots, never from the antialiased source. Pixel work runs off UI isolate.
Future<RasterPreview> rasterPreview(ui.Image source) async {
  if (source.width < 1 || source.width > 576 || source.height < 1 || source.height > 4096) {
    throw const FormatException('RASTER_PREVIEW_SIZE_INVALID');
  }
  final bytes = await source.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (bytes == null) throw const FormatException('RASTER_PREVIEW_IMAGE_FAILED');
  final prepared = await compute(_prepare, (width: source.width, height: source.height,
    rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)), debugLabel: 'receipt-raster');
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(prepared.pixels, source.width, source.height, ui.PixelFormat.rgba8888, decoded.complete);
  final preview = await decoded.future;
  try {
    final png = await preview.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('RASTER_PREVIEW_PNG_FAILED');
    return RasterPreview(prepared.raster, png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
  } finally { preview.dispose(); }
}
