import 'dart:typed_data';

/// Owned, immutable 1-bit image. One means black; rows are MSB-first and padded white.
class MonochromeRaster {
  MonochromeRaster._(this.width, this.height, Uint8List pixels)
    : pixels = pixels.asUnmodifiableView();
  final int width, height;
  final Uint8List pixels;
  int get rowBytes => (width + 7) ~/ 8;

  factory MonochromeRaster.fromStraightRgba({
    required int width,
    required int height,
    required Uint8List rgba,
    int threshold = 160,
  }) {
    if (width < 1 ||
        width > 576 ||
        height < 1 ||
        height > 4096 ||
        rgba.length != width * height * 4 ||
        threshold < 1 ||
        threshold > 254) {
      throw const FormatException('RECEIPT_RASTER_INVALID');
    }
    final stride = (width + 7) ~/ 8;
    final bits = Uint8List(stride * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final alpha = rgba[offset + 3];
        final weighted =
            rgba[offset] * 299 +
            rgba[offset + 1] * 587 +
            rgba[offset + 2] * 114;
        // Straight alpha composited onto white, not premultiplied RGBA.
        final luminance = (weighted * alpha + 255000 * (255 - alpha)) ~/ 255000;
        if (luminance < threshold) bits[y * stride + x ~/ 8] |= 0x80 >> (x % 8);
      }
    }
    return MonochromeRaster._(width, height, bits);
  }
}

/// Candidate GS v 0 encoder, not a verified XP-80U driver or a transmission API.
/// Optional fixed feed-to-cutter + partial cut, only on the final receipt page.
/// No arbitrary commands or cash-drawer access.
/// Caller must establish device support and an empty standard-mode print buffer.
Uint8List encodeGsV0(
  MonochromeRaster raster, {
  int stripeRows = 128,
  bool cutAtEnd = false,
}) {
  if (stripeRows < 1 || stripeRows > 256) {
    throw const FormatException('RECEIPT_STRIPE_INVALID');
  }
  final builder = BytesBuilder(copy: false);
  for (var y = 0; y < raster.height; y += stripeRows) {
    final rows = (raster.height - y).clamp(1, stripeRows);
    builder.add([
      0x1d,
      0x76,
      0x30,
      0,
      raster.rowBytes & 255,
      raster.rowBytes >> 8,
      rows & 255,
      rows >> 8,
    ]);
    builder.add(
      Uint8List.sublistView(
        raster.pixels,
        y * raster.rowBytes,
        (y + rows) * raster.rowBytes,
      ),
    );
  }
  if (cutAtEnd) builder.add([0x1d, 0x56, 66, 0]);
  return builder.takeBytes().asUnmodifiableView();
}
