import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/models/app_settings.dart';
import 'package:smabo/core/models/face_config.dart';
import 'package:smabo/core/models/face_expression.dart';
import 'package:smabo/core/models/face_schema.dart';

void main() {
  // test/face_schema.json is the shared contract: smabo-sim's tests compare
  // its own /face/schema with it. Regenerate with UPDATE_FACE_SCHEMA=1.
  test('schema matches test/face_schema.json', () {
    const enc = JsonEncoder.withIndent('  ');
    final file = File('test/face_schema.json');
    final now = '${enc.convert(faceSchemaJson())}\n';
    if (Platform.environment['UPDATE_FACE_SCHEMA'] == '1') file.writeAsStringSync(now);
    expect(file.readAsStringSync(), now);
  });

  test('expression to wire format and back', () {
    final x = FaceExpression.templates().firstWhere((e) => e.name == 'Wink');
    final j = expressionToJson(x);
    expect(j['id'], 8);
    expect(j['per_eye'], true);
    expect(j['left_eye']['shape'], 'round');
    expect(j['right_eye']['shape'], 'arc');
    expect(j['left_eye']['iris_color'], '#4FC3F7');
    expect(j.containsKey('images'), isFalse);
    expect(j['left_eye'].keys.toSet(), {for (final f in faceSchemaJson()['eye']) f['key']});
  });

  test('patch: typed, clamped, unknown and read-only listed back', () {
    final x = FaceExpression(id: 3, name: 'A', config: FaceConfig());
    final ignored = applyExpressionPatch(x, {
      'name': 'Surprised',
      'background': '#102030',
      'id': 9,
      'left_eye': {
        'shape': 'heart',
        'lid_top': 2,
        'iris_frac': 0.3,
        'pupil_frac': 0.9,
        'iris_color': 'red',
        'nope': 1,
      },
      'right_eye': 'x',
    });
    expect(ignored..sort(), ['id', 'left_eye.iris_color', 'left_eye.nope', 'right_eye']);
    expect(x.id, 3);
    expect(x.name, 'Surprised');
    expect(colorToHex(x.config.backgroundColor), '#102030');
    expect(x.config.leftEye.shape, EyeShape.heart);
    expect(x.config.leftEye.lidTop, 1.0);
    expect(x.config.leftEye.pupilFrac, 0.3); // ≤ iris
  });

  test('shared eyes: the right eye follows the left; turning per_eye on copies it', () {
    final x = FaceExpression(id: 1, name: 'A', config: FaceConfig());
    applyExpressionPatch(x, {'left_eye': {'lid_top': 0.4}, 'right_eye': {'lid_top': 0.9}});
    expect(x.config.rightEye.lidTop, 0.4);
    applyExpressionPatch(x, {'per_eye': true});
    expect(x.config.rightEye.lidTop, 0.4);
    applyExpressionPatch(x, {'right_eye': {'shape': 'arc'}});
    expect(x.config.leftEye.shape, EyeShape.round);
    expect(x.config.rightEye.shape, EyeShape.arc);
  });

  test('names are unique ignoring case', () {
    expect(expressionKey('  Angry '), 'angry');
    expect(uniqueExpressionName('angry', ['Angry', 'Sad']), 'angry 2');
    expect(uniqueExpressionName('Angry', ['Angry', 'angry 2']), 'Angry 3');
    expect(uniqueExpressionName('  ', []), 'Expression');
    final list = withUniqueNames([
      FaceExpression(id: 1, name: 'A', config: FaceConfig()),
      FaceExpression(id: 2, name: 'a', config: FaceConfig()),
      FaceExpression(id: 3, name: 'A', config: FaceConfig()),
    ]);
    expect([for (final e in list) e.name], ['A', 'a 2', 'A 3']);

    final x = FaceExpression(id: 1, name: 'A', config: FaceConfig());
    expect(applyExpressionPatch(x, {'name': 'ANGRY'}, taken: ['Angry']), ['name']);
    expect(x.name, 'A');
    expect(applyExpressionPatch(x, {'name': 'a'}, taken: ['Angry']), isEmpty); // its own name, new case
    expect(x.name, 'a');
  });

  test('AppSettings finds expressions by name', () {
    final s = AppSettings();
    expect(s.expressionByName(' wink ')?.id, 8);
    expect(s.expressionByName('nope'), isNull);
  });
}
