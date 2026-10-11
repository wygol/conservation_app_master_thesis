/// The capture frame: what the on-device model actually sees of a photograph.
///
/// The reference preprocessing (export_arm2.app_load, ported bit-exactly in
/// lib/ml/preprocess.dart) scales the SHORTER side of a photo to 224 px and cuts
/// out the centre square. Nothing outside that square ever reaches the model.
/// So the frame is not decoration: "put the plant in the frame" means "put it
/// where the model will look".
///
/// A centred square is the same set of scene points however the pixels are
/// rotated, so the frame stays right even when the camera stores the image
/// sideways with an EXIF orientation tag.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The square the model looks at, inside an image (or a preview of it) of [size].
Rect modelFieldOfView(Size size) {
  final side = math.min(size.width, size.height);
  return Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
}

/// Dims what the model will not see and marks the square it will, with corner
/// brackets — the usual camera-app idiom for "aim here".
class CaptureFramePainter extends CustomPainter {
  const CaptureFramePainter({
    required this.color,
    this.dimOutside = true,
    this.strokeWidth = 4,
  });

  final Color color;

  /// Shades the parts of the image that the model crops away.
  final bool dimOutside;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final square = modelFieldOfView(size);
    if (dimOutside) {
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(square);
      canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.45));
    }
    final r = square.deflate(strokeWidth / 2);
    final arm = r.shortestSide * 0.12;
    final pen = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner.translate(dx * arm, 0), pen);
      canvas.drawLine(corner, corner.translate(0, dy * arm), pen);
    }
  }

  @override
  bool shouldRepaint(CaptureFramePainter old) =>
      old.color != color || old.dimOutside != dimOutside || old.strokeWidth != strokeWidth;
}
