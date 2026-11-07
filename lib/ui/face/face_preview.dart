part of 'face_settings_screen.dart';

/// Animated face preview: gentle wandering gaze + occasional blink, rendered
/// from the live [AppState.faceConfig] so edits show immediately.
class _FacePreview extends StatefulWidget {
  const _FacePreview();

  @override
  State<_FacePreview> createState() => _FacePreviewState();
}

class _FacePreviewState extends State<_FacePreview> {
  Timer? _timer;
  double _t = 0;
  double _blink = 1.0;
  double _nextBlinkAt = 3;
  double _blinkPhase = -1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _t += 0.016;
      if (_blink >= 1.0 && _t >= _nextBlinkAt) {
        _blinkPhase = 0;
      }
      if (_blinkPhase >= 0) {
        _blinkPhase += 0.016 / 0.18;
        _blink = _blinkPhase < 0.5
            ? 1 - _blinkPhase / 0.5
            : (_blinkPhase - 0.5) / 0.5;
        _blink = _blink.clamp(0.0, 1.0);
        if (_blinkPhase >= 1.0) {
          _blinkPhase = -1;
          _blink = 1.0;
          _nextBlinkAt = _t + 2 + (_t % 3);
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final fc = state.faceConfig;
    final gx = math.sin(_t * 0.9) * 0.9;
    final gy = math.sin(_t * 0.6) * 0.7;

    final screen = MediaQuery.of(context).size;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: screen.width,
        height: screen.height,
        child: CustomPaint(
          size: Size(screen.width, screen.height),
          painter: EyePainter(
            gazeX: gx,
            gazeY: gy,
            blink: fc.blinkEnabled ? _blink : 1.0,
            backgroundColor: fc.backgroundColor,
            leftEye: fc.displayLeft,
            rightEye: fc.displayRight,
            perEye: fc.perEye,
            backgroundImage: state.faceImages['background'],
            leftImages: state.eyeImages('L'),
            rightImages: state.eyeImages('R'),
          ),
        ),
      ),
    );
  }
}
