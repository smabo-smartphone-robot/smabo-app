import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/models/face_config.dart';
import 'package:smabo/core/models/face_expression.dart';
import 'package:smabo/ui/face/face_render.dart';

void main() {
  test('renderFacePng draws the expression at the asked size', () async {
    final angry = FaceExpression.templates().firstWhere((e) => e.name == 'Angry');
    final png = await renderFacePng(angry.config, 200, 100);
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final img = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
    expect([img.width, img.height], [200, 100]);
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int at(int x, int y) => px.getUint32((y * 200 + x) * 4);
    expect(at(2, 2), 0x000000FF, reason: 'black background');
    expect(at(50, 50), 0x000000FF, reason: 'pupil at the centre of the left eye');
    expect(at(68, 50), 0xEF5350FF, reason: 'red iris around it');
  });

  test('an old save naming the removed image shape loads as round', () {
    final fc = FaceConfig.fromJson({'leftEye': {'shape': 5, 'irisImg': '/x.png'}, 'bgImg': '/y.png'});
    expect(fc.leftEye.shape, EyeShape.round);
    expect(fc.toJson().toString(), isNot(contains('Img')));
  });
}
