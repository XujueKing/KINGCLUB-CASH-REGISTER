import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'raster_preview.dart';

/// Financial previews must not use ImageProvider/Flutter's shared ImageCache.
/// Own the codec and decoded image, disposing stale results and page resources.
class PrivateRasterImage extends StatefulWidget {
  const PrivateRasterImage({super.key, required this.preview, required this.label, required this.failureLabel});
  final RasterPreview preview;
  final String label, failureLabel;
  @override State<PrivateRasterImage> createState() => _PrivateRasterImageState();
}
class _PrivateRasterImageState extends State<PrivateRasterImage> {
  ui.Image? image;
  bool failed = false;
  int epoch = 0;
  @override void initState() {super.initState(); unawaited(decode());}
  @override void didUpdateWidget(covariant PrivateRasterImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.preview, widget.preview)) {clear(); unawaited(decode());}
  }
  void clear() {epoch++; image?.dispose(); image = null; failed = false;}
  @override void dispose() {clear(); super.dispose();}
  Future<void> decode() async {
    final generation = ++epoch, preview = widget.preview;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      codec = await ui.instantiateImageCodec(preview.png);
      if (!mounted || epoch != generation) return;
      if (codec.frameCount != 1) throw const FormatException('RASTER_PREVIEW_INVALID');
      decoded = (await codec.getNextFrame()).image;
      if (!mounted || epoch != generation) return;
      if (decoded.width != preview.raster.width || decoded.height != preview.raster.height) {
        throw const FormatException('RASTER_PREVIEW_INVALID');
      }
      final owned = decoded;
      decoded = null;
      setState(() {image = owned; failed = false;});
    } catch (_) {
      if (mounted && epoch == generation) setState(() => failed = true);
    } finally {decoded?.dispose(); codec?.dispose();}
  }
  @override Widget build(BuildContext context) => failed ? Text(widget.failureLabel) :
    Semantics(label: widget.label, image: true, child: RawImage(image: image,
      fit: BoxFit.contain, filterQuality: FilterQuality.none));
}
