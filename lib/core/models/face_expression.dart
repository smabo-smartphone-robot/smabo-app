import 'dart:ui' show Color;

import 'face_config.dart';

/// One named, ID'd facial expression: a [FaceConfig] (colours, sizes and the
/// per-eye [EyeShapeParams]) plus a stable integer [id]. The [id] is shown in
/// the UI and is what a brain device sends over `/expression`
/// (`std_msgs/Int32`) to switch the active expression.
class FaceExpression {
  FaceExpression({
    required this.id,
    required this.name,
    required this.config,
  });

  /// Identifier shown in the UI and used by `/expression`. Auto-assigned
  /// (`max(id)+1`) but user-editable; must stay unique within the list.
  int id;
  String name;
  FaceConfig config;

  FaceExpression copy() =>
      FaceExpression(id: id, name: name, config: config.copy());

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'config': config.toJson(),
      };

  factory FaceExpression.fromJson(Map<String, dynamic> j) => FaceExpression(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? 'expression',
        config: FaceConfig.fromJson(
            ((j['config'] as Map?) ?? const {}).cast<String, dynamic>()),
      );

  /// The built-in templates seeded on first run and re-addable via
  /// "restore templates". Colour/shape only (no images) so they are portable.
  /// [id] == 1 is the neutral default and is used as the fallback expression.
  static List<FaceExpression> templates() {
    EyeAppearance eye({
      EyeShape shape = EyeShape.round,
      double lidTop = 0,
      double lidBottom = 0,
      Color iris = const Color(0xFF4FC3F7),
    }) =>
        EyeAppearance(
          shape: shape,
          lidTop: lidTop,
          lidBottom: lidBottom,
          irisColor: iris,
        );

    FaceConfig cfg({
      Color iris = const Color(0xFF4FC3F7),
      EyeAppearance? left,
      EyeAppearance? right,
      bool perEye = false,
      bool blink = true,
    }) {
      final l = left ?? eye(iris: iris);
      return FaceConfig(
        perEye: perEye,
        blinkEnabled: blink,
        leftEye: l,
        rightEye: right ?? l.copy(),
      );
    }

    return [
      FaceExpression(id: 1, name: 'Normal', config: cfg()),
      FaceExpression(
        id: 2,
        name: 'Sleepy',
        config: cfg(left: eye(lidTop: 0.55, lidBottom: 0.12)),
      ),
      FaceExpression(
        id: 3,
        name: 'Angry',
        config: cfg(
            left: eye(
                iris: const Color(0xFFEF5350), lidTop: 0.22)),
      ),
      FaceExpression(
        id: 4,
        name: 'Smile',
        config: cfg(
            blink: false,
            left: eye(iris: const Color(0xFF66BB6A), shape: EyeShape.arc)),
      ),
      FaceExpression(
        id: 5,
        name: 'Sad',
        config: cfg(
            left: eye(
                iris: const Color(0xFF42A5F5), lidTop: 0.3)),
      ),
      FaceExpression(
        id: 6,
        name: 'Love',
        config: cfg(
            blink: false,
            left: eye(iris: const Color(0xFFEC407A), shape: EyeShape.heart)),
      ),
      FaceExpression(
        id: 7,
        name: 'Dizzy',
        config: cfg(
            blink: false,
            left: eye(iris: const Color(0xFFBDBDBD), shape: EyeShape.swirl)),
      ),
      FaceExpression(
        id: 8,
        name: 'Wink',
        config: cfg(perEye: true, left: eye(), right: eye(shape: EyeShape.arc)),
      ),
    ];
  }
}
