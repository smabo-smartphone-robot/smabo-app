import 'dart:math';

import 'package:flutter/material.dart';

/// A draggable analog joystick. Reports a normalized vector where x is right
/// and y is up (both in [-1, 1]); returns to centre on release.
class Joystick extends StatefulWidget {
  const Joystick({
    super.key,
    required this.onChanged,
    this.size = 220,
    this.label,
  });

  final void Function(double x, double y) onChanged;
  final double size;
  final String? label;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero; // pixels from centre

  double get _radius => widget.size / 2;
  double get _maxKnob => _radius - widget.size * 0.18;

  void _update(Offset localPos) {
    final center = Offset(_radius, _radius);
    var delta = localPos - center;
    final dist = delta.distance;
    if (dist > _maxKnob) {
      delta = delta * (_maxKnob / dist);
    }
    setState(() => _knob = delta);
    // Normalize: x right, y up (invert screen y).
    widget.onChanged(delta.dx / _maxKnob, -delta.dy / _maxKnob);
  }

  void _reset() {
    setState(() => _knob = Offset.zero);
    widget.onChanged(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
        ],
        GestureDetector(
          onPanStart: (d) => _update(d.localPosition),
          onPanUpdate: (d) => _update(d.localPosition),
          onPanEnd: (_) => _reset(),
          onPanCancel: _reset,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _JoystickPainter(knob: _knob, radius: _radius),
            ),
          ),
        ),
      ],
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({required this.knob, required this.radius});
  final Offset knob;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(radius, radius);

    final base = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white10;
    canvas.drawCircle(center, radius, base);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white24;
    canvas.drawCircle(center, radius, ring);

    // Cross hairs.
    final hair = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy),
        hair);
    canvas.drawLine(
        Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius),
        hair);

    final knobCenter = center + knob;
    final knobR = radius * 0.32;
    final knobPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.cyanAccent, Colors.cyan.withOpacity(0.4)],
      ).createShader(Rect.fromCircle(center: knobCenter, radius: knobR));
    canvas.drawCircle(knobCenter, knobR, knobPaint);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter old) =>
      old.knob != knob || old.radius != radius;
}

/// Clamp a value into [-1, 1].
double clampUnit(double v) => max(-1.0, min(1.0, v));
