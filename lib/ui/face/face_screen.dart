import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/app_mode.dart';
import '../../services/speech_service.dart';
import '../../state/app_state.dart';
import 'eye_painter.dart';
import 'face_settings_screen.dart';

/// The face mode: two eyes filling the screen.
///
/// Random mode wanders the pupils on independent timers; follow mode tracks
/// the `/look_at` gaze target received from the brain device. Both modes blink
/// periodically. The current gaze is smoothly tweened toward the target so
/// movement looks natural.
class FaceScreen extends StatefulWidget {
  const FaceScreen({super.key});

  @override
  State<FaceScreen> createState() => _FaceScreenState();
}

class _FaceScreenState extends State<FaceScreen> {
  final _rng = Random();

  late final _Ticker _ticker = _Ticker(_onTick);

  // Smoothed current gaze and the target it eases toward.
  double _gx = 0, _gy = 0;
  double _tx = 0, _ty = 0;

  // Blink animation state.
  double _blink = 1.0;
  double _nextBlinkAt = 0;
  double _blinkPhase = -1; // -1 idle, else 0..1 progress
  double _elapsed = 0;

  // Random-mode retarget timer.
  double _nextRandomAt = 0;

  // Wake reaction: on each wake pulse the eyes change colour and hold it for a
  // fixed time (the eye size never changes). _reactUntil is an elapsed deadline.
  int _lastWakeCount = 0;
  double _reactUntil = 0;
  static const double _reactHold = 2.0; // seconds the colour stays lit

  @override
  void initState() {
    super.initState();
    // Seed with the current wake count so a pre-existing count (from an earlier
    // recognition) is not mistaken for a fresh wake when this screen is
    // recreated — e.g. on swiping back from another mode — which briefly
    // flashed the reaction colour.
    _lastWakeCount = context.read<AppState>().wakeCount;
    _scheduleBlink();
    _scheduleRandom();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _scheduleBlink() {
    _nextBlinkAt = _elapsed + 2.0 + _rng.nextDouble() * 4.0;
  }

  void _scheduleRandom() {
    _nextRandomAt = _elapsed + 0.8 + _rng.nextDouble() * 2.2;
  }

  void _onTick(double dt) {
    _elapsed += dt;
    final state = context.read<AppState>();

    // Wake pulse: hold the reaction colour for a fixed time so it does not snap
    // back the instant a (possibly very short) recognition session ends.
    if (state.wakeCount != _lastWakeCount) {
      _lastWakeCount = state.wakeCount;
      _reactUntil = _elapsed + _reactHold;
    }

    // Pick the target depending on the eye mode.
    if (state.eyeMode == EyeMode.follow) {
      final g = state.gazeTarget;
      if (g != null) {
        _tx = g.x;
        _ty = g.y;
      }
    } else {
      if (_elapsed >= _nextRandomAt) {
        // Random saccade, biased toward the centre.
        _tx = (_rng.nextDouble() * 2 - 1) * 0.8;
        _ty = (_rng.nextDouble() * 2 - 1) * 0.6;
        _scheduleRandom();
      }
    }

    // Ease current gaze toward target.
    const k = 8.0;
    final a = (k * dt).clamp(0.0, 1.0);
    _gx += (_tx - _gx) * a;
    _gy += (_ty - _gy) * a;

    // Blink (only when this expression has blinking enabled).
    if (!state.faceConfig.blinkEnabled) {
      _blink = 1.0;
      _blinkPhase = -1;
    } else {
      if (_blinkPhase < 0 && _elapsed >= _nextBlinkAt) {
        _blinkPhase = 0;
      }
      if (_blinkPhase >= 0) {
        _blinkPhase += dt / 0.18; // ~180ms blink
        // Triangle: open→closed→open.
        _blink = _blinkPhase < 0.5
            ? 1 - (_blinkPhase / 0.5)
            : (_blinkPhase - 0.5) / 0.5;
        _blink = _blink.clamp(0.0, 1.0);
        if (_blinkPhase >= 1.0) {
          _blinkPhase = -1;
          _blink = 1.0;
          _scheduleBlink();
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final listening = state.voiceState != VoiceState.idle;
    // The eyes only change COLOUR on wake (size never changes). While voice is
    // being accepted — i.e. recognizing a command or within the post-wake hold
    // window — the iris colour cycles continuously so it is clearly listening.
    final fc = state.faceConfig;
    final reacting = state.voiceState == VoiceState.recognizing ||
        _elapsed < _reactUntil;
    // While listening, the iris/line colour of every eye cycles through a
    // rainbow; otherwise each eye uses its own colour.
    final irisOverride = reacting
        ? HSVColor.fromAHSV(1.0, (_elapsed * 140.0) % 360.0, 0.7, 1.0).toColor()
        : null;

    return GestureDetector(
      // Single tap: manual voice capture (fallback for "smabo").
      // Double tap: reveal the hidden overlays.
      onTap: () => state.startVoiceCapture(),
      onDoubleTap: () => state.pokeChrome(),
      child: Container(
        color: fc.backgroundColor,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: EyePainter(
                  gazeX: _gx,
                  gazeY: _gy,
                  blink: _blink,
                  backgroundColor: fc.backgroundColor,
                  leftEye: fc.displayLeft,
                  rightEye: fc.displayRight,
                  perEye: fc.perEye,
                  irisOverride: irisOverride,
                  backgroundImage: state.faceImages['background'],
                  leftImages: state.eyeImages('L'),
                  rightImages: state.eyeImages('R'),
                ),
              ),
            ),

            // Face settings button (top-right) — part of the hideable chrome.
            if (state.chromeVisible)
              Positioned(
                top: 36,
                right: 8,
                child: TextButton.icon(
                  icon: const Icon(Icons.face_retouching_natural, size: 18),
                  label: const Text('Face settings'),
                  onPressed: () {
                    state.pokeChrome();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const FaceSettingsScreen(),
                      ),
                    );
                  },
                ),
              ),

            // Speech bubble: shows text received on /speech/say while the
            // bubble feature is on. Not part of the hideable chrome — it is
            // content, so it stays visible even after the overlays auto-hide.
            if (state.bubbleText.isNotEmpty)
              Align(
                alignment: const Alignment(0, -0.62),
                child: _SpeechBubble(text: state.bubbleText),
              ),

            // Eye-mode chip + speech feature toggles — part of the hideable
            // chrome.
            if (state.chromeVisible)
              Positioned(
              top: 44,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        state.pokeChrome();
                        final next = state.eyeMode == EyeMode.random
                            ? EyeMode.follow
                            : EyeMode.random;
                        state.setEyeMode(next);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              state.eyeMode == EyeMode.random
                                  ? Icons.shuffle
                                  : Icons.center_focus_strong,
                              size: 16,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              state.eyeMode == EyeMode.random
                                  ? 'Random'
                                  : 'Follow',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _FeatureChip(
                          icon: Icons.chat_bubble_outline,
                          label: '吹き出し',
                          active: state.speechBubbleEnabled,
                          onTap: () {
                            state.pokeChrome();
                            state.toggleSpeechBubble(!state.speechBubbleEnabled);
                          },
                        ),
                        const SizedBox(width: 8),
                        _FeatureChip(
                          icon: Icons.volume_up_outlined,
                          label: '発話',
                          active: state.ttsEnabled,
                          onTap: () {
                            state.pokeChrome();
                            state.toggleTts(!state.ttsEnabled);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Voice feedback. During wake-listening we also show what the STT
            // currently hears, so a non-matching transcription is visible.
            if (listening && state.chromeVisible)
              Positioned(
                bottom: 84,
                left: 0,
                right: 0,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.voiceState == VoiceState.recognizing
                            ? '🎤 ${state.lastPartial}'
                            : 'Say "${state.settings.wakeWord}"',
                        style: const TextStyle(
                            color: Colors.cyanAccent, fontSize: 16),
                      ),
                      if (state.voiceState == VoiceState.listeningForWake)
                        Text(
                          state.lastPartial.isEmpty
                              ? '(tap the screen to talk)'
                              : 'Heard: ${state.lastPartial}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small pill toggle used on the face screen to switch a feature on/off.
/// When [active] the pill is tinted (cyan); when off it is dimmed.
class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.cyanAccent : Colors.white38;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.cyanAccent.withOpacity(0.15) : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Colors.cyanAccent.withOpacity(0.6) : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
            const SizedBox(width: 6),
            Text(
              active ? 'ON' : 'OFF',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A rounded speech bubble with a downward tail, drawn over the face to show
/// text received on `/speech/say`.
class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 320),
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF1A1A2E),
              fontSize: 18,
              height: 1.3,
            ),
          ),
        ),
        // Tail pointing down toward the face.
        CustomPaint(
          size: const Size(22, 12),
          painter: _BubbleTailPainter(),
        ),
      ],
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A minimal frame ticker giving delta-time callbacks (avoids depending on the
/// scheduler binding API surface directly in the widget).
class _Ticker {
  _Ticker(this.onTick);
  final void Function(double dt) onTick;
  Timer? _timer;
  DateTime _last = DateTime.now();

  void start() {
    _last = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final dt = now.difference(_last).inMicroseconds / 1e6;
      _last = now;
      onTick(dt);
    });
  }

  void dispose() => _timer?.cancel();
}
