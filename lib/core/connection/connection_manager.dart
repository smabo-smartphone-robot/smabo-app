import '../models/app_settings.dart';
import '../wire/ws_client.dart';

/// Owns the WebSocket connection to the brain device.
///
/// The brain (PC / Raspberry Pi) handles eye-follow gaze, speech, and sensor
/// streams. It speaks the same rosbridge v2.0 JSON protocol as smabo-app.
class ConnectionManager {
  ConnectionManager() : brain = WsClient(label: 'Brain');

  final WsClient brain;

  void applySettings(AppSettings settings) {
    brain.connect(settings.brainUrl);
  }

  Future<void> disconnectAll() async {
    await brain.disconnect();
  }

  void dispose() {
    brain.dispose();
  }
}
