import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../services/sensor_service.dart';
import '../../state/app_state.dart';

/// Live preview of the phone sensors (camera image, IMU, GPS) in settings.
/// Each can be toggled on here; values update live via the service streams.
class SensorPreview extends StatelessWidget {
  const SensorPreview({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tile(
          'Camera',
          state.camera.isStreaming,
          (v) => state.toggleCamera(v),
          _cameraPreview(context),
        ),
        _tile(
          'IMU',
          state.sensors.imuOn,
          (v) => state.toggleImu(v),
          _imuPreview(),
        ),
        _tile(
          'GPS',
          state.sensors.gpsOn,
          (v) => state.toggleGps(v),
          _gpsPreview(),
        ),
      ],
    );
  }

  Widget _tile(
      String title, bool on, ValueChanged<bool> onToggle, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          value: on,
          onChanged: onToggle,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 12),
          child: on ? child : const _Hint('Turn on to preview'),
        ),
      ],
    );
  }

  // ----------------------------------------------------------- camera
  Widget _cameraPreview(BuildContext context) {
    final c = state.camera.controller;
    if (c == null || !c.value.isInitialized) {
      return const _Hint('Starting camera…');
    }
    // controller.aspectRatio is the sensor ratio in landscape; invert it when
    // the screen is portrait so the preview is not stretched.
    final sensor = c.value.aspectRatio;
    final portrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    final ratio = portrait ? 1 / sensor : sensor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: AspectRatio(
          aspectRatio: ratio,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- IMU
  Widget _imuPreview() {
    return StreamBuilder<ImuSample>(
      stream: state.sensors.imuStream,
      initialData: state.sensors.lastImu,
      builder: (_, snap) {
        final s = snap.data;
        if (s == null) return const _Hint('Waiting for IMU…');
        const r2d = 180.0 / 3.141592653589793;
        String v3(List<double> a) =>
            '${a[0].toStringAsFixed(2)}, ${a[1].toStringAsFixed(2)}, ${a[2].toStringAsFixed(2)}';
        return _mono([
          'accel (m/s²):  ${v3(s.accel)}',
          'gyro  (rad/s): ${v3(s.gyro)}',
          'orient (°): roll ${(s.roll * r2d).toStringAsFixed(1)}, '
              'pitch ${(s.pitch * r2d).toStringAsFixed(1)}, '
              'yaw ${(s.yaw * r2d).toStringAsFixed(1)}',
        ]);
      },
    );
  }

  // -------------------------------------------------------------- GPS
  Widget _gpsPreview() {
    return StreamBuilder<Position>(
      stream: state.sensors.gpsStream,
      initialData: state.sensors.lastGps,
      builder: (_, snap) {
        final p = snap.data;
        if (p == null) return const _Hint('Waiting for GPS fix…');
        return _mono([
          'lat: ${p.latitude.toStringAsFixed(6)}',
          'lon: ${p.longitude.toStringAsFixed(6)}',
          'alt: ${p.altitude.toStringAsFixed(1)} m',
          'accuracy: ±${p.accuracy.toStringAsFixed(1)} m',
        ]);
      },
    );
  }

  Widget _mono(List<String> lines) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Text(l,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.cyanAccent)),
        ],
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Colors.white38, fontSize: 12));
}
