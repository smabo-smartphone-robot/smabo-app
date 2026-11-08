import 'dart:ui' show Color;

import 'face_config.dart';

/// [name] as expressions are matched: case and surrounding spaces don't count.
String expressionKey(String name) => name.trim().toLowerCase();

/// [base], or "[base] 2", "[base] 3", … whichever no name in [taken] matches.
String uniqueExpressionName(String base, Iterable<String> taken) {
  final used = {for (final n in taken) expressionKey(n)};
  base = base.trim().isEmpty ? 'Expression' : base.trim();
  if (!used.contains(expressionKey(base))) return base;
  for (var i = 2;; i++) {
    final n = '$base $i';
    if (!used.contains(expressionKey(n))) return n;
  }
}

/// [list] with every name made unique (later duplicates get " 2", " 3", …),
/// for saves from before names had to be unique.
List<FaceExpression> withUniqueNames(List<FaceExpression> list) {
  final taken = <String>[];
  for (final e in list) {
    e.name = uniqueExpressionName(e.name, taken);
    taken.add(e.name);
  }
  return list;
}

/// One named facial expression: a [FaceConfig] (colours, sizes and the per-eye
/// [EyeAppearance]) plus an internal integer [id]. The [name] is unique
/// (ignoring case) and is how others pick it: a brain device sends it over
/// `/expression` (`std_msgs/String`), smabo-web sets it as `face.expression`.
/// The [id] is only this app's handle (storage, the `/face/expressions/<id>`
/// editing API) and is never shown or edited.
class FaceExpression {
  FaceExpression({
    required this.id,
    required this.name,
    required this.config,
  });

  /// Internal handle, auto-assigned (`max(id)+1`) and unique.
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
  /// "restore templates".
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
