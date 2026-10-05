import 'package:flutter/material.dart';

/// Shared scan symbol, using the supplied 1024 x 1024 SVG outline.
class ScanIcon extends StatelessWidget {
  const ScanIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final extent = size ?? theme.size ?? 24;
    final ink = color ?? theme.color ?? const Color(0xff262626);
    return Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: extent,
        child: CustomPaint(
          painter: _ScanPainter(
            ink.withValues(alpha: ink.a * (theme.opacity ?? 1)),
          ),
        ),
      ),
    );
  }
}

class _ScanPainter extends CustomPainter {
  const _ScanPainter(this.color);
  final Color color;

  static final outline = Path()
    ..moveTo(885.312, 885.312)
    ..lineTo(885.312, 624)
    ..lineTo(960, 624)
    ..lineTo(960, 960)
    ..lineTo(624, 960)
    ..lineTo(624, 885.312)
    ..close()
    ..moveTo(64, 885.312)
    ..lineTo(64, 624)
    ..lineTo(138.688, 624)
    ..lineTo(138.688, 885.312)
    ..lineTo(400, 885.312)
    ..lineTo(400, 960)
    ..lineTo(64, 960)
    ..close()
    ..moveTo(960, 138.688)
    ..lineTo(960, 400)
    ..lineTo(885.312, 400)
    ..lineTo(885.312, 138.688)
    ..lineTo(624, 138.688)
    ..lineTo(624, 64)
    ..lineTo(960, 64)
    ..close()
    ..moveTo(138.688, 138.688)
    ..lineTo(138.688, 400)
    ..lineTo(64, 400)
    ..lineTo(64, 64)
    ..lineTo(400, 64)
    ..lineTo(400, 138.688)
    ..close()
    ..addRect(const Rect.fromLTRB(64, 474.688, 960, 549.312));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    canvas.drawPath(outline, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScanPainter oldDelegate) =>
      oldDelegate.color != color;
}
