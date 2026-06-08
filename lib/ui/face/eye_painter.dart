import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/models/face_config.dart';

/// Draws a pair of robot eyes, each from its own [EyeAppearance] so the two eyes
/// can differ entirely (shape, colours, sizes, images). The only shared element
/// is the screen [backgroundColor]/[backgroundImage], which is also what the
/// eyelids (blink + [EyeAppearance.lidTop]/[lidBottom]) blend into.
///
/// [EyeShape.round] draws the sclera/iris/pupil/highlight; the other shapes draw
/// their silhouette directly over the background using the eye's [irisColor] as
/// the line/fill colour. [irisOverride], when set, replaces every eye's iris/line
/// colour (used to flash the configured colour while voice recognition is active).
class EyePainter extends CustomPainter {
  EyePainter({
    required this.gazeX,
    required this.gazeY,
    required this.blink,
    required this.backgroundColor,
    required this.leftEye,
    required this.rightEye,
    this.perEye = false,
    this.irisOverride,
    this.backgroundImage,
    this.leftImages = const {},
    this.rightImages = const {},
  });

  final double gazeX;
  final double gazeY;
  final double blink; // 1 open .. 0 closed

  final Color backgroundColor;
  final EyeAppearance leftEye;
  final EyeAppearance rightEye;
  final bool perEye;
  final Color? irisOverride;

  final ui.Image? backgroundImage;
  // Decoded element images per eye, keyed by slot ('sclera'/'iris'/'pupil'/
  // 'highlight'); missing/absent entries fall back to the solid colour.
  final Map<String, ui.Image?> leftImages;
  final Map<String, ui.Image?> rightImages;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);

    final cy = size.height * 0.5;
    // When the eyes are shared (not perEye) the right eye mirrors the left
    // (lid tilt and shape rotation) so the face is symmetric; with independent
    // eyes each uses its own.
    final rightRotation = perEye ? rightEye.rotation : -leftEye.rotation;
    final rightShapeRotation =
        perEye ? rightEye.shapeRotation : -leftEye.shapeRotation;
    _drawEye(canvas, size, Offset(size.width * 0.25, cy), leftEye, leftImages,
        isLeft: true,
        lidRotation: leftEye.rotation,
        shapeRotation: leftEye.shapeRotation);
    _drawEye(canvas, size, Offset(size.width * 0.75, cy), rightEye, rightImages,
        isLeft: false,
        lidRotation: rightRotation,
        shapeRotation: rightShapeRotation);
  }

  /// Fill the whole canvas with the background colour, then the background
  /// image on top (used both for the screen and to "close" the eyelid).
  void _paintBackground(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    if (backgroundImage != null) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: backgroundImage!,
        fit: BoxFit.cover,
      );
    }
  }

  void _drawEye(Canvas canvas, Size size, Offset center, EyeAppearance eye,
      Map<String, ui.Image?> images,
      {required bool isLeft,
      required double lidRotation,
      required double shapeRotation}) {
    final t = blink.clamp(0.0, 1.0);
    final maxR = math.min(size.width * 0.22, size.height * 0.46);
    final scleraR =
        (size.height * 0.36 * eye.scleraScale).clamp(8.0, maxR).toDouble();
    final lineColor = irisOverride ?? eye.irisColor;

    canvas.save();
    // Clip every shape to the eye circle except a free-form custom image, which
    // is shown in full (e.g. a transparent PNG of any silhouette).
    if (eye.shape != EyeShape.image) {
      canvas.clipPath(
          Path()..addOval(Rect.fromCircle(center: center, radius: scleraR)));
    }

    if (t > 0.04) {
      canvas.save();
      if (shapeRotation != 0) {
        canvas.translate(center.dx, center.dy);
        canvas.rotate(shapeRotation * math.pi / 180.0);
        canvas.translate(-center.dx, -center.dy);
      }
      switch (eye.shape) {
        case EyeShape.round:
          _drawRound(canvas, center, scleraR, eye, images, lineColor);
          break;
        case EyeShape.arc:
          _drawArc(canvas, center, scleraR, lineColor);
          break;
        case EyeShape.heart:
          _drawHeart(canvas, center, scleraR, eye, lineColor);
          break;
        case EyeShape.swirl:
          _drawSwirl(canvas, center, scleraR, lineColor);
          break;
        case EyeShape.squeeze:
          _drawSqueeze(canvas, center, scleraR, lineColor, isLeft);
          break;
        case EyeShape.image:
          _drawImage(canvas, center, scleraR, images['iris']);
          break;
      }
      canvas.restore();
    }

    // Eyelids: redraw the background over the covered segments. The top lid
    // combines blinking (1 - t) with the configured lidTop; the bottom lid uses
    // lidBottom.
    final topCover = math.max(eye.lidTop, 1.0 - t).clamp(0.0, 1.0).toDouble();
    // Both lids tilt the same way (a rigid tilt of the eye opening); the right
    // eye's [lidRotation] is mirrored by the caller for a symmetric face.
    _drawTopLid(canvas, size, center, scleraR, topCover, lidRotation);
    _drawBottomLid(canvas, size, center, scleraR,
        eye.lidBottom.clamp(0.0, 1.0).toDouble(), lidRotation);

    canvas.restore();
  }

  /// Normal eyeball: sclera + iris + pupil + highlight, offset by the gaze.
  void _drawRound(Canvas canvas, Offset center, double scleraR,
      EyeAppearance eye, Map<String, ui.Image?> images, Color irisColor) {
    _fill(canvas, center, scleraR, eye.scleraColor, images['sclera']);

    final irisR = scleraR * eye.irisFrac;
    final pupilR = scleraR * eye.pupilFrac;

    // Recomputed travel range: the iris centre can move at most
    // (sclera - iris) so the iris never spills outside the sclera.
    final maxOff = math.max(0.0, scleraR - irisR);
    final c = center.translate(gazeX * maxOff, gazeY * maxOff);

    _fill(canvas, c, irisR, irisColor, images['iris']);
    _fill(canvas, c, pupilR, eye.pupilColor, images['pupil']);

    if (eye.highlightVisible) {
      final hR = irisR * eye.highlightFrac;
      final off = math.max(0.0, irisR - hR); // keep highlight inside iris
      final hc = c.translate(eye.highlightX * off, eye.highlightY * off);
      _fill(canvas, hc, hR, eye.highlightColor, images['highlight']);
    }
  }

  /// A happy/laughing closed eye: an upward arch stroke ("⌒", like ^).
  void _drawArc(Canvas canvas, Offset center, double scleraR, Color color) {
    final p = Path()
      ..moveTo(center.dx - scleraR * 0.72, center.dy + scleraR * 0.18)
      ..quadraticBezierTo(center.dx, center.dy - scleraR * 0.55,
          center.dx + scleraR * 0.72, center.dy + scleraR * 0.18);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = scleraR * 0.2
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  /// A heart filling the eye (the "love" expression), with a small highlight.
  void _drawHeart(
      Canvas canvas, Offset center, double scleraR, EyeAppearance eye, Color color) {
    final w = scleraR * 1.35;
    final h = scleraR * 1.35;
    final cx = center.dx;
    final cy = center.dy + scleraR * 0.08;
    final path = Path()
      ..moveTo(cx, cy + h * 0.35)
      ..cubicTo(cx - w * 0.5, cy - h * 0.08, cx - w * 0.5, cy - h * 0.55, cx,
          cy - h * 0.22)
      ..cubicTo(cx + w * 0.5, cy - h * 0.55, cx + w * 0.5, cy - h * 0.08, cx,
          cy + h * 0.35)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    if (eye.highlightVisible) {
      canvas.drawCircle(
        Offset(cx - w * 0.18, cy - h * 0.18),
        scleraR * 0.12,
        Paint()..color = eye.highlightColor,
      );
    }
  }

  /// A static spiral (the "dizzy/ぐるぐる" expression).
  void _drawSwirl(Canvas canvas, Offset center, double scleraR, Color color) {
    final path = Path();
    const turns = 3.0;
    const steps = 140;
    final maxR = scleraR * 0.85;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final ang = f * turns * 2 * math.pi;
      final r = f * maxR;
      final x = center.dx + r * math.cos(ang);
      final y = center.dy + r * math.sin(ang);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = scleraR * 0.12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  /// A squeezed/excited closed eye: ">" on the left eye and "<" on the right
  /// (both vertices point inward), giving the "><" look.
  void _drawSqueeze(
      Canvas canvas, Offset center, double scleraR, Color color, bool isLeft) {
    final baseX = center.dx + (isLeft ? -scleraR * 0.5 : scleraR * 0.5);
    final vertexX = center.dx + (isLeft ? scleraR * 0.48 : -scleraR * 0.48);
    final p = Path()
      ..moveTo(baseX, center.dy - scleraR * 0.5)
      ..lineTo(vertexX, center.dy)
      ..lineTo(baseX, center.dy + scleraR * 0.5);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = scleraR * 0.18
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  /// A user-picked image filling the eye (BoxFit.contain in a square the size of
  /// the eye). Until an image is chosen, a faint placeholder outline is shown.
  void _drawImage(Canvas canvas, Offset center, double scleraR, ui.Image? img) {
    if (img == null) {
      final rect = Rect.fromCenter(
          center: center, width: scleraR * 1.6, height: scleraR * 1.6);
      canvas.drawRRect(
        RRect.fromRectXY(rect, scleraR * 0.15, scleraR * 0.15),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = scleraR * 0.05
          ..color = const Color(0x55FFFFFF),
      );
      return;
    }
    paintImage(
      canvas: canvas,
      rect: Rect.fromCenter(
          center: center, width: scleraR * 2, height: scleraR * 2),
      image: img,
      fit: BoxFit.contain,
    );
  }

  void _drawTopLid(Canvas canvas, Size size, Offset center, double scleraR,
      double coverFrac, double rotationDeg) {
    if (coverFrac <= 0) return;
    final top = center.dy - scleraR;
    final edge = top + coverFrac * 2 * scleraR;
    final curve = scleraR * 0.16;
    final lid = Path()
      ..moveTo(center.dx - scleraR, top)
      ..lineTo(center.dx + scleraR, top)
      ..lineTo(center.dx + scleraR, edge)
      ..quadraticBezierTo(center.dx, edge + curve, center.dx - scleraR, edge)
      ..close();
    _paintLid(canvas, size, center, lid, rotationDeg);
  }

  void _drawBottomLid(Canvas canvas, Size size, Offset center, double scleraR,
      double coverFrac, double rotationDeg) {
    if (coverFrac <= 0) return;
    final bottom = center.dy + scleraR;
    final edgeY = bottom - coverFrac * 2 * scleraR;
    final curve = scleraR * 0.16;
    final lid = Path()
      ..moveTo(center.dx - scleraR, bottom)
      ..lineTo(center.dx + scleraR, bottom)
      ..lineTo(center.dx + scleraR, edgeY)
      ..quadraticBezierTo(
          center.dx, edgeY - curve, center.dx - scleraR, edgeY)
      ..close();
    _paintLid(canvas, size, center, lid, rotationDeg);
  }

  /// Clip to [lid] (rotated by [rotationDeg] about [center] so the eyelid tilts,
  /// leaving the eye itself upright) and redraw the background over it.
  void _paintLid(
      Canvas canvas, Size size, Offset center, Path lid, double rotationDeg) {
    canvas.save();
    if (rotationDeg != 0) {
      canvas.translate(center.dx, center.dy);
      canvas.rotate(rotationDeg * math.pi / 180.0);
      canvas.translate(-center.dx, -center.dy);
    }
    canvas.clipPath(lid);
    _paintBackground(canvas, size);
    canvas.restore();
  }

  /// Fill a circle with a colour, or cover it with an image if given.
  void _fill(Canvas canvas, Offset center, double r, Color color, ui.Image? img) {
    if (r <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: r);
    if (img == null) {
      canvas.drawCircle(center, r, Paint()..color = color);
    } else {
      canvas.save();
      canvas.clipPath(Path()..addOval(rect));
      paintImage(canvas: canvas, rect: rect, image: img, fit: BoxFit.cover);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant EyePainter o) {
    return o.gazeX != gazeX ||
        o.gazeY != gazeY ||
        o.blink != blink ||
        o.backgroundColor != backgroundColor ||
        o.irisOverride != irisOverride ||
        o.perEye != perEye ||
        !o.leftEye.sameAs(leftEye) ||
        !o.rightEye.sameAs(rightEye) ||
        o.backgroundImage != backgroundImage ||
        o.leftImages != leftImages ||
        o.rightImages != rightImages;
  }
}
