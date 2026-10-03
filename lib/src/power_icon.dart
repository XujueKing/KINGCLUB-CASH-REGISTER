import 'package:flutter/material.dart';

/// Exact outline from the supplied 1024 × 1024 power SVG.
class PowerIcon extends StatelessWidget {
  const PowerIcon({super.key});
  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(23, 23), painter: _PowerPainter());
}

class _PowerPainter extends CustomPainter {
  const _PowerPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 1024, size.height / 1024);
    final path = Path()
      ..moveTo(320, 192)
      ..relativeLineTo(0, 106.432)
      ..relativeCubicTo(-97.28, 61.12, -161.792, 167.68, -161.792, 289.024)
      ..relativeCubicTo(0, 189.632, 157.632, 343.36, 352, 343.36)
      ..relativeCubicTo(194.432, 0, 352, -153.728, 352, -343.36)
      ..relativeCubicTo(0, -119.808, -62.848, -225.28, -158.208, -286.72)
      ..lineTo(704, 192)
      ..relativeCubicTo(151.36, 70.144, 256, 220.608, 256, 394.944)
      ..cubicTo(960, 828.352, 759.424, 1024, 512, 1024)
      ..relativeCubicTo(-247.424, 0, -448, -195.648, -448, -437.056)
      ..cubicTo(64, 412.608, 168.64, 262.144, 320, 192)
      ..close()
      ..moveTo(448, 0)
      ..relativeLineTo(128, 0)
      ..lineTo(576, 448)
      ..lineTo(448, 448)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff262626)
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _PowerPainter oldDelegate) => false;
}
