import 'dart:ui' show Color;

import 'face_config.dart';
import 'face_expression.dart';

/// Face expressions over REST (`/face/...` on the settings API, port 8081),
/// described by a schema so smabo-web can build its editor without knowing
/// the fields: `GET /face/schema` returns [faceSchemaJson].
///
/// An expression on the wire (colours as "#RRGGBB", shape as a name):
/// ```
/// {"id": 1, "name": "Normal", "background": "#000000", "blink": true, "per_eye": false,
///  "left_eye": {"shape": "round", "lid_top": 0.0, ...}, "right_eye": {...}}
/// ```
/// `GET /face/preview.png?id=<id>&w=&h=` is the expression drawn by the
/// phone's own painter (eyes straight ahead, open), for smabo-web's preview.
/// smabo-sim serves the same (smabo_sim/phone/expressions.py). The schema is
/// kept in test/face_schema.json, which tests in both repositories compare with.

/// One editable field of an expression or of an eye.
class FaceField<T> {
  const FaceField(this.key, this.type, this.label,
      {required this.get,
      required this.set,
      this.group,
      this.min,
      this.max,
      this.step,
      this.options,
      this.shapes,
      this.when});

  final String key;
  final String type; // bool | number | color | string | enum
  final String label;
  final String? group;
  final double? min, max, step;
  final List<String>? options;

  /// Eye shapes the field applies to (null = all).
  final List<String>? shapes;

  /// A bool field of the same object that must be true for this one to matter.
  final String? when;
  final Object? Function(T) get;
  final void Function(T, Object) set;

  Map<String, dynamic> toSchema() => {
        'key': key,
        'type': type,
        'label': label,
        if (group != null) 'group': group,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (step != null) 'step': step,
        if (options != null) 'options': options,
        if (shapes != null) 'shapes': shapes,
        if (when != null) 'when': when,
      };

  /// [raw] as this field's value, or null when it doesn't fit.
  Object? coerce(Object? raw) {
    switch (type) {
      case 'bool':
        return raw is bool ? raw : null;
      case 'number':
        if (raw is! num || !raw.isFinite) return null;
        return raw.toDouble().clamp(min ?? double.negativeInfinity, max ?? double.infinity);
      case 'color':
        return raw is String ? colorFromHex(raw) : null;
      case 'string':
        return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
      case 'enum':
        return raw is String && options!.contains(raw) ? raw : null;
    }
    return null;
  }
}

String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? colorFromHex(String s) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(s.trim());
  return m == null ? null : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

const _round = ['round'];
const _roundHeart = ['round', 'heart'];
const _lined = ['round', 'arc', 'heart', 'swirl', 'squeeze'];

final eyeFields = <FaceField<EyeAppearance>>[
  FaceField('shape', 'enum', 'Shape',
      group: 'Shape',
      options: [for (final s in EyeShape.values) s.name],
      get: (e) => e.shape.name,
      set: (e, v) => e.shape = EyeShape.values.byName(v as String)),
  FaceField('sclera_color', 'color', 'Sclera (white)',
      group: 'Shape', shapes: _round,
      get: (e) => colorToHex(e.scleraColor), set: (e, v) => e.scleraColor = v as Color),
  FaceField('iris_color', 'color', 'Iris / line color',
      group: 'Shape', shapes: _lined,
      get: (e) => colorToHex(e.irisColor), set: (e, v) => e.irisColor = v as Color),
  FaceField('sclera_scale', 'number', 'Size',
      group: 'Shape', min: 0.3, max: 1.6, step: 0.01,
      get: (e) => e.scleraScale, set: (e, v) => e.scleraScale = v as double),
  FaceField('shape_rotation', 'number', 'Rotation (°)',
      group: 'Shape', min: -180, max: 180, step: 1,
      get: (e) => e.shapeRotation, set: (e, v) => e.shapeRotation = v as double),
  FaceField('iris_frac', 'number', 'Iris size',
      group: 'Iris & pupil', shapes: _round, min: 0.1, max: 1.0, step: 0.01,
      get: (e) => e.irisFrac, set: (e, v) => e.irisFrac = v as double),
  FaceField('pupil_color', 'color', 'Pupil color',
      group: 'Iris & pupil', shapes: _round,
      get: (e) => colorToHex(e.pupilColor), set: (e, v) => e.pupilColor = v as Color),
  FaceField('pupil_frac', 'number', 'Pupil size (≤ iris size)',
      group: 'Iris & pupil', shapes: _round, min: 0.05, max: 1.0, step: 0.01,
      get: (e) => e.pupilFrac, set: (e, v) => e.pupilFrac = v as double),
  FaceField('highlight_visible', 'bool', 'Highlight',
      group: 'Highlight', shapes: _roundHeart,
      get: (e) => e.highlightVisible, set: (e, v) => e.highlightVisible = v as bool),
  FaceField('highlight_color', 'color', 'Highlight color',
      group: 'Highlight', shapes: _roundHeart, when: 'highlight_visible',
      get: (e) => colorToHex(e.highlightColor), set: (e, v) => e.highlightColor = v as Color),
  FaceField('highlight_frac', 'number', 'Highlight size',
      group: 'Highlight', shapes: _round, when: 'highlight_visible', min: 0.05, max: 0.6, step: 0.01,
      get: (e) => e.highlightFrac, set: (e, v) => e.highlightFrac = v as double),
  FaceField('highlight_x', 'number', 'Highlight X',
      group: 'Highlight', shapes: _round, when: 'highlight_visible', min: -1, max: 1, step: 0.01,
      get: (e) => e.highlightX, set: (e, v) => e.highlightX = v as double),
  FaceField('highlight_y', 'number', 'Highlight Y',
      group: 'Highlight', shapes: _round, when: 'highlight_visible', min: -1, max: 1, step: 0.01,
      get: (e) => e.highlightY, set: (e, v) => e.highlightY = v as double),
  FaceField('lid_top', 'number', 'Upper lid',
      group: 'Eyelid', min: 0, max: 1, step: 0.01,
      get: (e) => e.lidTop, set: (e, v) => e.lidTop = v as double),
  FaceField('lid_bottom', 'number', 'Lower lid',
      group: 'Eyelid', min: 0, max: 1, step: 0.01,
      get: (e) => e.lidBottom, set: (e, v) => e.lidBottom = v as double),
  FaceField('rotation', 'number', 'Lid tilt (°)',
      group: 'Eyelid', min: -180, max: 180, step: 1,
      get: (e) => e.rotation, set: (e, v) => e.rotation = v as double),
];

final expressionFields = <FaceField<FaceExpression>>[
  FaceField('name', 'string', 'Name (unique: /expression picks it by name)',
      get: (x) => x.name, set: (x, v) => x.name = v as String),
  FaceField('background', 'color', 'Background (also the eyelids)',
      get: (x) => colorToHex(x.config.backgroundColor),
      set: (x, v) => x.config.backgroundColor = v as Color),
  FaceField('blink', 'bool', 'Blink',
      get: (x) => x.config.blinkEnabled, set: (x, v) => x.config.blinkEnabled = v as bool),
  FaceField('per_eye', 'bool', 'Separate left / right eyes',
      get: (x) => x.config.perEye, set: (x, v) => x.config.perEye = v as bool),
];

const faceSchemaVersion = 1;

Map<String, dynamic> faceSchemaJson() => {
      'schema': faceSchemaVersion,
      'expression': [for (final f in expressionFields) f.toSchema()],
      'eye': [for (final f in eyeFields) f.toSchema()],
      'eyes': ['left_eye', 'right_eye'],
      'notes': {
        'right_eye': 'used only when per_eye is true; otherwise it mirrors left_eye',
      },
    };

Map<String, dynamic> eyeToJson(EyeAppearance e) => {for (final f in eyeFields) f.key: f.get(e)};

Map<String, dynamic> expressionToJson(FaceExpression x) => {
      'id': x.id,
      for (final f in expressionFields) f.key: f.get(x),
      'left_eye': eyeToJson(x.config.leftEye),
      'right_eye': eyeToJson(x.config.rightEye),
    };

/// Apply a partial expression to [x] in place. Returns the ignored paths.
/// A name that one in [taken] already has (ignoring case) is ignored.
///
/// Like the app's editor: with shared eyes (per_eye false) the right eye is a
/// copy of the left, and turning per_eye on starts the right eye as that copy.
List<String> applyExpressionPatch(FaceExpression x, Map<String, dynamic> patch,
    {Iterable<String> taken = const []}) {
  final used = {for (final n in taken) expressionKey(n)};
  final wasPerEye = x.config.perEye;
  final ignored = <String>[];
  patch.forEach((k, v) {
    if (k == 'left_eye' || k == 'right_eye') {
      if (v is! Map) {
        ignored.add(k);
        return;
      }
      final eye = k == 'left_eye' ? x.config.leftEye : x.config.rightEye;
      v.cast<String, dynamic>().forEach((ek, ev) {
        final f = eyeFields.where((f) => f.key == ek).firstOrNull;
        final value = f?.coerce(ev);
        if (f == null || value == null) {
          ignored.add('$k.$ek');
        } else {
          f.set(eye, value);
        }
      });
      if (eye.pupilFrac > eye.irisFrac) eye.pupilFrac = eye.irisFrac;
      return;
    }
    final f = expressionFields.where((f) => f.key == k).firstOrNull;
    final value = f?.coerce(v);
    if (f == null || value == null || (k == 'name' && used.contains(expressionKey(value as String)))) {
      ignored.add(k); // id and unknown keys
    } else {
      f.set(x, value);
    }
  });
  if (!x.config.perEye || (!wasPerEye && !patch.containsKey('right_eye'))) {
    x.config.rightEye = x.config.leftEye.copy();
  }
  return ignored;
}
