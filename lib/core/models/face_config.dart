import 'dart:convert';
import 'dart:ui' show Color;

/// Overall silhouette of an eye. [round] is the normal eyeball (iris/pupil);
/// the others replace it with a static shape used by expression templates.
///   - [arc]     : an upward "^" arch — a happy/laughing closed eye.
///   - [heart]   : a heart — the "love" expression.
///   - [swirl]   : a static spiral — the "dizzy/ぐるぐる" expression.
///   - [squeeze] : ">" (left) / "<" (right) — the squeezed "><" expression.
///   - [image]   : a user-picked image fills the eye (uses the iris image slot).
enum EyeShape { round, arc, heart, swirl, squeeze, image }

/// The complete appearance of ONE eye: its [shape], the eyelid morph
/// ([lidTop]/[lidBottom]) and all colours/sizes/images. Each eye owns
/// its own copy so the two eyes can differ entirely (see [FaceConfig.perEye]);
/// the screen background is the only shared element ([FaceConfig.backgroundColor]).
///
/// Which fields actually matter depends on [shape]: [round] uses the sclera/iris/
/// pupil/highlight and their sizes; [heart] uses [irisColor] (the heart) plus the
/// highlight; [arc]/[swirl]/[squeeze] only use [irisColor] as the line colour.
/// All shapes honour the eyelids ([lidTop]/[lidBottom]).
class EyeAppearance {
  EyeAppearance({
    this.shape = EyeShape.round,
    this.lidTop = 0.0,
    this.lidBottom = 0.0,
    this.rotation = 0.0,
    this.shapeRotation = 0.0,
    this.scleraColor = const Color(0xFFFFFFFF),
    this.irisColor = const Color(0xFF4FC3F7),
    this.pupilColor = const Color(0xFF000000),
    this.highlightColor = const Color(0xFFFFFFFF),
    this.scleraScale = 1.0,
    this.irisFrac = 0.62,
    this.pupilFrac = 0.41,
    this.highlightVisible = true,
    this.highlightFrac = 0.30,
    this.highlightX = -0.32,
    this.highlightY = -0.34,
    this.scleraImage,
    this.irisImage,
    this.pupilImage,
    this.highlightImage,
  });

  EyeShape shape;
  double lidTop; // 0 fully open .. 1 fully covered from the top
  double lidBottom; // 0 .. 1 covered from the bottom
  double rotation; // eyelid rotation/tilt in degrees (-180..180)
  double shapeRotation; // rotation of the eye shape itself in degrees (-180..180)

  Color scleraColor;
  Color irisColor; // also the line/fill colour for arc/heart/swirl/squeeze
  Color pupilColor;
  Color highlightColor;

  double scleraScale;
  double irisFrac;
  double pupilFrac;

  bool highlightVisible;
  double highlightFrac;
  double highlightX;
  double highlightY;

  String? scleraImage;
  String? irisImage;
  String? pupilImage;
  String? highlightImage;

  static const slots = ['sclera', 'iris', 'pupil', 'highlight'];

  String? imageForSlot(String slot) {
    switch (slot) {
      case 'sclera':
        return scleraImage;
      case 'iris':
        return irisImage;
      case 'pupil':
        return pupilImage;
      case 'highlight':
        return highlightImage;
    }
    return null;
  }

  void setImageForSlot(String slot, String? path) {
    switch (slot) {
      case 'sclera':
        scleraImage = path;
        break;
      case 'iris':
        irisImage = path;
        break;
      case 'pupil':
        pupilImage = path;
        break;
      case 'highlight':
        highlightImage = path;
        break;
    }
  }

  EyeAppearance copy() => EyeAppearance(
        shape: shape,
        lidTop: lidTop,
        lidBottom: lidBottom,
        rotation: rotation,
        shapeRotation: shapeRotation,
        scleraColor: scleraColor,
        irisColor: irisColor,
        pupilColor: pupilColor,
        highlightColor: highlightColor,
        scleraScale: scleraScale,
        irisFrac: irisFrac,
        pupilFrac: pupilFrac,
        highlightVisible: highlightVisible,
        highlightFrac: highlightFrac,
        highlightX: highlightX,
        highlightY: highlightY,
        scleraImage: scleraImage,
        irisImage: irisImage,
        pupilImage: pupilImage,
        highlightImage: highlightImage,
      );

  EyeAppearance clamped() {
    final c = copy();
    c.scleraScale = c.scleraScale.clamp(0.3, 1.6);
    c.irisFrac = c.irisFrac.clamp(0.1, 1.0);
    c.pupilFrac = c.pupilFrac.clamp(0.05, c.irisFrac);
    c.highlightFrac = c.highlightFrac.clamp(0.05, 0.6);
    c.highlightX = c.highlightX.clamp(-1.0, 1.0);
    c.highlightY = c.highlightY.clamp(-1.0, 1.0);
    c.lidTop = c.lidTop.clamp(0.0, 1.0);
    c.lidBottom = c.lidBottom.clamp(0.0, 1.0);
    c.rotation = c.rotation.clamp(-180.0, 180.0);
    c.shapeRotation = c.shapeRotation.clamp(-180.0, 180.0);
    return c;
  }

  bool sameAs(EyeAppearance o) =>
      o.shape == shape &&
      o.lidTop == lidTop &&
      o.lidBottom == lidBottom &&
      o.rotation == rotation &&
      o.shapeRotation == shapeRotation &&
      o.scleraColor == scleraColor &&
      o.irisColor == irisColor &&
      o.pupilColor == pupilColor &&
      o.highlightColor == highlightColor &&
      o.scleraScale == scleraScale &&
      o.irisFrac == irisFrac &&
      o.pupilFrac == pupilFrac &&
      o.highlightVisible == highlightVisible &&
      o.highlightFrac == highlightFrac &&
      o.highlightX == highlightX &&
      o.highlightY == highlightY;

  Map<String, dynamic> toJson() => {
        'shape': shape.index,
        'lidTop': lidTop,
        'lidBottom': lidBottom,
        'rotation': rotation,
        'shapeRotation': shapeRotation,
        'scleraColor': scleraColor.toARGB32(),
        'irisColor': irisColor.toARGB32(),
        'pupilColor': pupilColor.toARGB32(),
        'highlightColor': highlightColor.toARGB32(),
        'scleraScale': scleraScale,
        'irisFrac': irisFrac,
        'pupilFrac': pupilFrac,
        'highlightVisible': highlightVisible,
        'highlightFrac': highlightFrac,
        'highlightX': highlightX,
        'highlightY': highlightY,
        'scleraImg': scleraImage,
        'irisImg': irisImage,
        'pupilImg': pupilImage,
        'hlImg': highlightImage,
      };

  factory EyeAppearance.fromJson(Map<String, dynamic> j) {
    Color col(String k, int d) => Color((j[k] as num?)?.toInt() ?? d);
    double dbl(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    final si = (j['shape'] as num?)?.toInt() ?? 0;
    return EyeAppearance(
      shape: si >= 0 && si < EyeShape.values.length
          ? EyeShape.values[si]
          : EyeShape.round,
      lidTop: dbl('lidTop', 0),
      lidBottom: dbl('lidBottom', 0),
      rotation: dbl('rotation', 0),
      shapeRotation: dbl('shapeRotation', 0),
      scleraColor: col('scleraColor', 0xFFFFFFFF),
      irisColor: col('irisColor', 0xFF4FC3F7),
      pupilColor: col('pupilColor', 0xFF000000),
      highlightColor: col('highlightColor', 0xFFFFFFFF),
      scleraScale: dbl('scleraScale', 1.0),
      irisFrac: dbl('irisFrac', 0.62),
      pupilFrac: dbl('pupilFrac', 0.41),
      highlightVisible: j['highlightVisible'] != false,
      highlightFrac: dbl('highlightFrac', 0.30),
      highlightX: dbl('highlightX', -0.32),
      highlightY: dbl('highlightY', -0.34),
      scleraImage: j['scleraImg'] as String?,
      irisImage: j['irisImg'] as String?,
      pupilImage: j['pupilImg'] as String?,
      highlightImage: j['hlImg'] as String?,
    );
  }

  /// Which appearance fields are meaningful for [shape] — used by the settings
  /// UI to show only the relevant controls per eye type.
  bool get usesSclera => shape == EyeShape.round;
  bool get usesPupil => shape == EyeShape.round;
  bool get usesSizes => shape == EyeShape.round;
  bool get usesHighlight => shape == EyeShape.round || shape == EyeShape.heart;
}

/// Customisable appearance of the face (eyes) on the face screen.
///
/// The only shared element is the screen background (also the eyelid colour);
/// everything else lives per eye in [leftEye]/[rightEye] ([EyeAppearance]). When
/// [perEye] is false the two eyes share [leftEye] (so [displayRight] returns it
/// too); set [perEye] for fully independent eyes (e.g. a wink or different
/// colours per eye).
class FaceConfig {
  FaceConfig({
    this.backgroundColor = const Color(0xFF000000),
    this.backgroundImage,
    this.blinkEnabled = true,
    this.perEye = false,
    EyeAppearance? leftEye,
    EyeAppearance? rightEye,
  })  : leftEye = leftEye ?? EyeAppearance(),
        rightEye = rightEye ?? (leftEye?.copy() ?? EyeAppearance());

  Color backgroundColor; // also the eyelid colour (blink blends into it)
  String? backgroundImage;

  /// Whether the eyes blink periodically for this expression (off for e.g.
  /// closed/sleepy or swirl looks).
  bool blinkEnabled;

  /// When false the two eyes share [leftEye]; set true for independent eyes.
  bool perEye;
  EyeAppearance leftEye;
  EyeAppearance rightEye;

  /// Appearance actually used for drawing, resolving [perEye].
  EyeAppearance get displayLeft => leftEye;
  EyeAppearance get displayRight => perEye ? rightEye : leftEye;

  FaceConfig clamped() {
    final c = copy();
    c.leftEye = c.leftEye.clamped();
    c.rightEye = c.rightEye.clamped();
    return c;
  }

  FaceConfig copy() => FaceConfig(
        backgroundColor: backgroundColor,
        backgroundImage: backgroundImage,
        blinkEnabled: blinkEnabled,
        perEye: perEye,
        leftEye: leftEye.copy(),
        rightEye: rightEye.copy(),
      );

  Map<String, dynamic> toJson() => {
        'bg': backgroundColor.toARGB32(),
        'bgImg': backgroundImage,
        'blink': blinkEnabled,
        'perEye': perEye,
        'leftEye': leftEye.toJson(),
        'rightEye': rightEye.toJson(),
      };

  factory FaceConfig.fromJson(Map<String, dynamic> j) {
    // Legacy shared appearance (pre per-eye) used as a fallback so old saves
    // migrate: the old top-level colours/sizes/images seed each eye, while any
    // per-eye keys present override them.
    final legacy = <String, dynamic>{
      if (j['sclera'] != null) 'scleraColor': j['sclera'],
      if (j['iris'] != null) 'irisColor': j['iris'],
      if (j['pupil'] != null) 'pupilColor': j['pupil'],
      if (j['hl'] != null) 'highlightColor': j['hl'],
      if (j['scleraScale'] != null) 'scleraScale': j['scleraScale'],
      if (j['irisFrac'] != null) 'irisFrac': j['irisFrac'],
      if (j['pupilFrac'] != null) 'pupilFrac': j['pupilFrac'],
      if (j['hlVisible'] != null) 'highlightVisible': j['hlVisible'],
      if (j['hlFrac'] != null) 'highlightFrac': j['hlFrac'],
      if (j['hlX'] != null) 'highlightX': j['hlX'],
      if (j['hlY'] != null) 'highlightY': j['hlY'],
      if (j['scleraImg'] != null) 'scleraImg': j['scleraImg'],
      if (j['irisImg'] != null) 'irisImg': j['irisImg'],
      if (j['pupilImg'] != null) 'pupilImg': j['pupilImg'],
      if (j['hlImg'] != null) 'hlImg': j['hlImg'],
    };

    EyeAppearance eye(Object? raw) {
      final m = <String, dynamic>{...legacy};
      if (raw is Map) m.addAll(raw.cast<String, dynamic>());
      return EyeAppearance.fromJson(m);
    }

    final left = eye(j['leftEye']);
    return FaceConfig(
      backgroundColor: Color((j['bg'] as num?)?.toInt() ?? 0xFF000000),
      backgroundImage: j['bgImg'] as String?,
      blinkEnabled: j['blink'] != false,
      perEye: j['perEye'] == true,
      leftEye: left,
      rightEye: j['rightEye'] != null ? eye(j['rightEye']) : left.copy(),
    );
  }

  String encode() => jsonEncode(toJson());

  factory FaceConfig.decode(String? s) {
    if (s == null || s.isEmpty) return FaceConfig();
    try {
      return FaceConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return FaceConfig();
    }
  }
}
