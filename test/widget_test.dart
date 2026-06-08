// Unit tests for the rosbridge message builders/parsers.
//
// These run without a device and verify ROS message interoperability.

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/wire/ros_compat.dart';

void main() {
  test('twist maps forward and turn correctly', () {
    final t = RosMessages.twist(0.2, 0.3);
    expect((t['linear'] as Map)['x'], 0.2);
    expect((t['angular'] as Map)['z'], 0.3);
  });

  test('jointTrajectory builds a single timed point in radians', () {
    final m = RosMessages.jointTrajectory(['arm_joint_1'], [1.0],
        timeFromStart: 0.5);
    final points = m['points'] as List;
    expect(m['joint_names'], ['arm_joint_1']);
    expect((points.first as Map)['positions'], [1.0]);
    final t = (points.first as Map)['time_from_start'] as Map;
    expect(t['sec'], 0);
    expect(t['nanosec'], 500000000);
  });

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

  test('parseOdom reads twist velocities', () {
    final o = RosMessages.parseOdom({
      'pose': {
        'pose': {
          'position': {'x': 0.1, 'y': 0.2, 'z': 0.0}
        }
      },
      'twist': {
        'twist': {
          'linear': {'x': 0.18, 'y': 0, 'z': 0},
          'angular': {'x': 0, 'y': 0, 'z': 0.05},
        }
      },
    });
    expect(o, isNotNull);
    expect(o!.linearX, 0.18);
    expect(o.angularZ, 0.05);
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
}
