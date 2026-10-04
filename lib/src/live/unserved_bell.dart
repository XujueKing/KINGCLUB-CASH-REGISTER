import 'dart:math' as math;

import 'package:flutter/material.dart';

class UnservedBell extends StatefulWidget {
  const UnservedBell({super.key});
  @override
  State<UnservedBell> createState() => _UnservedBellState();
}

class _UnservedBellState extends State<UnservedBell>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();
  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Unserved items',
    child: AnimatedBuilder(
      animation: animation,
      builder: (_, child) => Transform.rotate(
        angle: MediaQuery.disableAnimationsOf(context)
            ? 0
            : math.sin(animation.value * math.pi * 4) * 0.18,
        alignment: Alignment.topCenter,
        child: child,
      ),
      child: const SizedBox(
        width: 20,
        height: 22,
        child: CustomPaint(painter: _BellPainter()),
      ),
    ),
  );
}

/// User-supplied bell silhouette, including the lightning-shaped cutout.
class _BellPainter extends CustomPainter {
  const _BellPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 1024, size.height / 1024);
    final p = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(168.176581, 709.482978)
      ..lineTo(168.176581, 402.116972)
      ..relativeCubicTo(
        0,
        -148.766679,
        118.119466,
        -272.760195,
        275.058735,
        -301.236563,
      )
      ..lineTo(443.235316, 0.063848)
      ..relativeLineTo(137.529368, 0)
      ..relativeLineTo(0, 100.752713)
      ..relativeCubicTo(
        156.875421,
        28.476369,
        275.058736,
        152.533732,
        275.058735,
        301.236563,
      )
      ..relativeLineTo(0, 307.429854)
      ..lineTo(958.938521, 709.482978)
      ..relativeLineTo(0, 126.100511)
      ..lineTo(65.061479, 835.583489)
      ..lineTo(65.061479, 709.482978)
      ..close()
      ..moveTo(659.362015, 896.30328)
      ..relativeCubicTo(
        0,
        70.552438,
        -61.613668,
        127.69672,
        -137.529368,
        127.69672,
      )
      ..cubicTo(445.853099, 1024, 384.30328, 966.855718, 384.30328, 896.30328)
      ..close()
      ..moveTo(612.688864, 223.277715)
      ..relativeLineTo(-97.432598, 0.383091)
      ..relativeLineTo(-175.136052, 272.249407)
      ..relativeLineTo(80.895873, 0.638484)
      ..relativeLineTo(133.315376, 0)
      ..lineTo(436.46739, 679.857339)
      ..relativeLineTo(98.90111, 0)
      ..lineTo(703.54508, 416.99364)
      ..relativeLineTo(-204.953236, -0.574635)
      ..lineTo(612.752712, 223.341564)
      ..close();
    canvas.drawPath(p, Paint()..color = const Color(0xffffd600));
  }

  @override
  bool shouldRepaint(_BellPainter oldDelegate) => false;
}
