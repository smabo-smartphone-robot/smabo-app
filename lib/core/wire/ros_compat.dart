import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;

// rosbridge-compatibility layer.
//
// This is the ONLY place in the app that knows about ROS message shapes. The
// app does not run or depend on ROS; it just sends/receives WebSocket JSON.
// These builders/parsers produce payloads whose structure matches standard ROS
// messages so that, if a `rosbridge_suite` bridge is placed in front of an
// endpoint, the data interoperates unchanged. Nothing here imports a ROS
// library — it is plain JSON shaping.

/// Topic names exchanged with the brain device.
///
/// This app is a sensor + face peripheral: it publishes its phone sensors and
/// renders the face. All robot driving / arm control lives in smabo-web, not
/// here.
///
///   - [lookAt] is received (eye-follow target, geometry_msgs/PoseStamped shape).
///   - [speechAudio] is published (recorded utterance for smabo-brain to
///     transcribe; the text comes back on [speechRecognized], shown in smabo-web).
///   - [speechSay] is received (text to read aloud, std_msgs/String shape).
///   - [faceExpression] is received (active expression id, std_msgs/Int32 shape).
///   - [imu] / [gps] are published (sensors). The camera is streamed over
///     WebRTC (see services/webrtc_service.dart), not as a ROS topic here.
class RosTopics {
  // --- brain: face / voice ---
  static const lookAt = '/look_at';
  static const speechRecognized = '/speech/recognized';
  static const speechSay = '/speech/say';

  /// Recorded utterance sent to smabo-brain (audio_common_msgs/AudioData:
  /// `{data: <base64 WAV>}`), which runs STT and publishes the text on
  /// [speechRecognized].
  static const speechAudio = '/speech/audio';

  /// Active facial-expression id, received from the brain device
  /// (std_msgs/Int32 shape: `{data: <id>}`).
  static const faceExpression = '/expression';

  // --- brain: sensors ---
  static const imu = '/imu/data';
  static const gps = '/gps/fix';
}

/// ROS-compatible message type strings (used in the optional `subscribe` op).
class RosTypes {
  static const poseStamped = 'geometry_msgs/PoseStamped';
  static const pose = 'geometry_msgs/Pose';
  static const string = 'std_msgs/String';
  static const int32 = 'std_msgs/Int32';
  static const imu = 'sensor_msgs/Imu';
  static const navSatFix = 'sensor_msgs/NavSatFix';
}

/// A ROS time `{sec, nanosec}` from the current wall clock.
Map<String, dynamic> rosTimeNow() {
  final us = DateTime.now().microsecondsSinceEpoch;
  return {
    'sec': us ~/ 1000000,
    'nanosec': (us % 1000000) * 1000,
  };
}

/// A `std_msgs/Header` with the current stamp and the given frame.
Map<String, dynamic> rosHeader(String frameId) {
  return {'stamp': rosTimeNow(), 'frame_id': frameId};
}

/// Builders and parsers for the ROS message bodies exchanged with the brain.
///
/// Every method maps directly onto standard ROS message definitions, so the
/// output is interoperable with `rosbridge_suite`.
class RosMessages {
  // ---------------------------------------------------------------------- //
  // std_msgs/String  ← /speech/say  (text to read aloud, in)
  // ---------------------------------------------------------------------- //
  /// Extract the text from a std_msgs/String (`/speech/say`).
  static String? parseString(Map<String, dynamic> msg) {
    final d = msg['data'];
    return d is String ? d : null;
  }

  // ---------------------------------------------------------------------- //
  // std_msgs/Int32  ↔ /expression  (active expression id)
  // ---------------------------------------------------------------------- //
  static Map<String, dynamic> int32(int data) => {'data': data};

  /// Extract an integer from a std_msgs/Int32 (`{data: <int>}`).
  static int? parseInt32(Map<String, dynamic> msg) {
    final d = msg['data'];
    if (d is num) return d.toInt();
    if (d is String) return int.tryParse(d);
    return null;
  }

  // ---------------------------------------------------------------------- //
  // geometry_msgs/PoseStamped (or Pose) ← /look_at  (eye-follow target)
  // ---------------------------------------------------------------------- //
  /// Parse a look-at target into a normalized 2D gaze direction.
  ///
  /// Accepts either a `geometry_msgs/PoseStamped` (`{header, pose:{...}}`) or a
  /// bare `geometry_msgs/Pose`. The position's x/y/z are interpreted as a
  /// direction in the robot frame (REP-103: x forward, y left, z up) and
  /// projected to a screen gaze vector where +x(right) follows -y, and
  /// +y(down) follows -z.
  static GazeTarget? parseLookAt(Map<String, dynamic> msg) {
    final pose = msg.containsKey('pose')
        ? msg['pose'] as Map<String, dynamic>?
        : msg;
    if (pose == null) return null;
    final pos = pose['position'] as Map<String, dynamic>?;
    if (pos == null) return null;
    final x = _toD(pos['x']); // forward
    final y = _toD(pos['y']); // left
    final z = _toD(pos['z']); // up

    // Project the (left, up) components relative to forward distance so a
    // closer/larger offset gives a larger gaze. Guard against a zero/negative
    // forward distance.
    final fwd = x.abs() < 0.05 ? 0.05 : x.abs();
    final gazeX = (-y / fwd).clamp(-1.0, 1.0); // screen right
    final gazeY = (-z / fwd).clamp(-1.0, 1.0); // screen down
    return GazeTarget(gazeX.toDouble(), gazeY.toDouble());
  }

  // ---------------------------------------------------------------------- //
  // sensor_msgs/Imu  → /imu/data
  // ---------------------------------------------------------------------- //
  /// Build a sensor_msgs/Imu from accelerometer (m/s^2), gyroscope (rad/s) and
  /// an orientation quaternion. Unknown covariances are left as zeros except a
  /// leading -1 sentinel is NOT used (we report the data we have).
  static Map<String, dynamic> imu({
    required vm.Quaternion orientation,
    required List<double> angularVelocity,
    required List<double> linearAcceleration,
  }) {
    return {
      'header': rosHeader('imu_link'),
      'orientation': {
        'x': orientation.x,
        'y': orientation.y,
        'z': orientation.z,
        'w': orientation.w,
      },
      'orientation_covariance': List<double>.filled(9, 0.0),
      'angular_velocity': {
        'x': angularVelocity[0],
        'y': angularVelocity[1],
        'z': angularVelocity[2],
      },
      'angular_velocity_covariance': List<double>.filled(9, 0.0),
      'linear_acceleration': {
        'x': linearAcceleration[0],
        'y': linearAcceleration[1],
        'z': linearAcceleration[2],
      },
      'linear_acceleration_covariance': List<double>.filled(9, 0.0),
    };
  }

  // ---------------------------------------------------------------------- //
  // sensor_msgs/NavSatFix  → /gps/fix
  // ---------------------------------------------------------------------- //
  static Map<String, dynamic> navSatFix({
    required double latitude,
    required double longitude,
    required double altitude,
    required double horizontalAccuracy,
  }) {
    final cov = horizontalAccuracy * horizontalAccuracy;
    return {
      'header': rosHeader('gps'),
      // status: STATUS_FIX=0, SERVICE_GPS=1
      'status': {'status': 0, 'service': 1},
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'position_covariance': [
        cov, 0.0, 0.0,
        0.0, cov, 0.0,
        0.0, 0.0, cov,
      ],
      // COVARIANCE_TYPE_APPROXIMATED = 1
      'position_covariance_type': 1,
    };
  }

  static double _toD(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
}

/// A normalized 2D gaze direction in screen space: x right, y down, each in
/// [-1, 1].
class GazeTarget {
  const GazeTarget(this.x, this.y);
  final double x;
  final double y;
}

/// Convert roll/pitch/yaw (radians) to a quaternion (ROS xyzw order).
vm.Quaternion quaternionFromEuler(double roll, double pitch, double yaw) {
  final cy = math.cos(yaw * 0.5);
  final sy = math.sin(yaw * 0.5);
  final cp = math.cos(pitch * 0.5);
  final sp = math.sin(pitch * 0.5);
  final cr = math.cos(roll * 0.5);
  final sr = math.sin(roll * 0.5);
  return vm.Quaternion(
    sr * cp * cy - cr * sp * sy, // x
    cr * sp * cy + sr * cp * sy, // y
    cr * cp * sy - sr * sp * cy, // z
    cr * cp * cy + sr * sp * sy, // w
  );
}
