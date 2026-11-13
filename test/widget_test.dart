// Unit tests for the rosbridge message builders/parsers and the brain protocol.
//
// These run without a device and verify ROS message interoperability.

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/wire/ros_compat.dart';

void main() {
  test('parseLookAt projects a left/up pose to screen gaze', () {
    // forward 1m, left 0.5m, up 0.0 → gaze right is negative (left side).
    final g = RosMessages.parseLookAt({
      'pose': {
        'position': {'x': 1.0, 'y': 0.5, 'z': 0.0},
        'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1},
      }
    });
    expect(g, isNotNull);
    expect(g!.x, lessThan(0)); // left target → pupil moves left
    expect(g.y, 0.0);
  });

  test('navSatFix builds an approximated covariance', () {
    final m = RosMessages.navSatFix(
      latitude: 35.0,
      longitude: 139.0,
      altitude: 10.0,
      horizontalAccuracy: 2.0,
    );
    expect(m['latitude'], 35.0);
    expect((m['position_covariance'] as List)[0], 4.0); // 2^2
    expect(m['position_covariance_type'], 1);
  });

  test('handshake tables use canonical topics; publish is sent with /app', () {
    expect(RosProtocol.sourcePrefix, '/app');
    for (final t in [
      ...RosProtocol.publish.keys,
      ...RosProtocol.subscribe.keys,
    ]) {
      expect(t.startsWith('/app/'), isFalse, reason: t);
      expect(t.startsWith('/'), isTrue, reason: t);
    }
    expect(
        RosProtocol.subscribe.keys,
        containsAll(
            [RosTopics.faceExpression, RosTopics.lookAt, RosTopics.speechSay]));
  });
}
