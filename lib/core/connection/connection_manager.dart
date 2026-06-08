import '../models/app_settings.dart';
import '../wire/ws_client.dart';

/// Owns the two WebSocket endpoints and routes traffic to the right one.
///
/// - [esp32] : robot hardware — drive, servos/arm, config, odom, joint states.
/// - [brain] : a second device (e.g. a PC or Raspberry Pi) for eye-follow
///   gaze, speech, and sensor streams.
///
/// Both are plain WebSocket connections that exchange JSON. The message shapes
/// happen to be rosbridge v2.0 compatible (so a `rosbridge_suite` bridge can
/// sit in front of either endpoint), but the app itself uses no ROS runtime.
class ConnectionManager {
  ConnectionManager()
      : esp32 = WsClient(label: 'ESP32'),
        brain = WsClient(label: 'Brain');

  final WsClient esp32;
  final WsClient brain;

  /// (Re)connect both endpoints to the URLs in [settings].
  void applySettings(AppSettings settings) {
    esp32.connect(settings.esp32Url);
    brain.connect(settings.brainUrl);
  }

  Future<void> disconnectAll() async {
    await esp32.disconnect();
    await brain.disconnect();
  }

  void dispose() {
    esp32.dispose();
    brain.dispose();
  }
}
