import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/models/face_config.dart';
import 'eye_painter.dart';

/// [fc] drawn by the face screen's own [EyePainter] (eyes open, looking
/// straight ahead) as a PNG of [width]×[height] pixels: smabo-web's expression
/// preview (`GET /face/preview.png`).
Future<Uint8List> renderFacePng(FaceConfig fc, int width, int height) async {
  final size = Size(width.toDouble(), height.toDouble());
  final recorder = ui.PictureRecorder();
  EyePainter(
    gazeX: 0,
    gazeY: 0,
    blink: 1,
    backgroundColor: fc.backgroundColor,
    leftEye: fc.displayLeft,
    rightEye: fc.displayRight,
    perEye: fc.perEye,
  ).paint(Canvas(recorder, Offset.zero & size), size);
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
