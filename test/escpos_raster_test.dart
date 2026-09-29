import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';

void main() {
  test('MSB-first rows and white padding do not bleed across rows', () {
    final rgba = Uint8List(9 * 2 * 4)..fillRange(0, 9 * 2 * 4, 255);
    for (final pixel in [0, 7, 8, 10]) {
      rgba[pixel * 4] = 0;
      rgba[pixel * 4 + 1] = 0;
      rgba[pixel * 4 + 2] = 0;
    }
    final raster = MonochromeRaster.fromStraightRgba(
      width: 9,
      height: 2,
      rgba: rgba,
    );
    expect(raster.pixels, [0x81, 0x80, 0x40, 0]);
    rgba.fillRange(0, rgba.length, 0);
    expect(raster.pixels, [0x81, 0x80, 0x40, 0]);
    expect(() => raster.pixels[0] = 0, throwsUnsupportedError);
  });

  test('straight alpha composites on white and threshold is deterministic', () {
    final raster = MonochromeRaster.fromStraightRgba(
      width: 6,
      height: 1,
      rgba: Uint8List.fromList([
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        100,
        159,
        159,
        159,
        255,
        160,
        160,
        160,
        255,
        255,
        255,
        255,
        255,
      ]),
    );
    expect(raster.pixels, [0x70]);
  });

  test(
    'invalid dimensions, byte lengths and thresholds fail before allocation',
    () {
      for (final dimensions in [
        [0, 1],
        [577, 1],
        [1, 0],
        [1, 4097],
        [-1, 1],
      ]) {
        expect(
          () => MonochromeRaster.fromStraightRgba(
            width: dimensions[0],
            height: dimensions[1],
            rgba: Uint8List(0),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => MonochromeRaster.fromStraightRgba(
          width: 1,
          height: 1,
          rgba: Uint8List(3),
        ),
        throwsFormatException,
      );
      for (final threshold in [0, 255, -1, 256]) {
        expect(
          () => MonochromeRaster.fromStraightRgba(
            width: 1,
            height: 1,
            rgba: Uint8List(4),
            threshold: threshold,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('wire bytes consist only of explicit GS v 0 frames and exact raster payload', () {
    final rgba = Uint8List(576 * 257 * 4)..fillRange(0, 576 * 257 * 4, 255);
    for (var pixel = 0; pixel < 576 * 257; pixel += 3) {
      rgba[pixel * 4] = 0;
      rgba[pixel * 4 + 1] = 0;
      rgba[pixel * 4 + 2] = 0;
    }
    final raster = MonochromeRaster.fromStraightRgba(
      width: 576,
      height: 257,
      rgba: rgba,
    );
    final encoded = encodeGsV0(raster);
    var offset = 0, sourceOffset = 0;
    final heights = <int>[];
    while (offset < encoded.length) {
      expect(encoded.sublist(offset, offset + 4), [0x1d, 0x76, 0x30, 0]);
      final widthBytes = encoded[offset + 4] + encoded[offset + 5] * 256;
      final rows = encoded[offset + 6] + encoded[offset + 7] * 256;
      expect(widthBytes, 72);
      heights.add(rows);
      offset += 8;
      final length = widthBytes * rows;
      expect(
        encoded.sublist(offset, offset + length),
        raster.pixels.sublist(sourceOffset, sourceOffset + length),
      );
      sourceOffset += length;
      offset += length;
    }
    expect(heights, [128, 128, 1]);
    expect(sourceOffset, raster.pixels.length);
    expect(
      offset,
      encoded.length,
    ); // No trailing feed/cut/drawer/reset commands.
    expect(() => encoded[0] = 0, throwsUnsupportedError);
  });

  test('256-row stripe height uses both little-endian bytes', () {
    final raster = MonochromeRaster.fromStraightRgba(
      width: 8,
      height: 256,
      rgba: Uint8List(8 * 256 * 4),
    );
    expect(encodeGsV0(raster, stripeRows: 256).sublist(0, 8), [
      29,
      118,
      48,
      0,
      1,
      0,
      0,
      1,
    ]);
    for (final size in [0, -1, 257]) {
      expect(() => encodeGsV0(raster, stripeRows: size), throwsFormatException);
    }
  });
}
