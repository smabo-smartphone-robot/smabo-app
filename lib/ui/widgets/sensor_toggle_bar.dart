import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// Bottom overlay with one toggle chip per sensor stream (camera, IMU, GPS).
///
/// Available from every mode so sensor publishing can be switched on/off at
/// any time, as required. Each chip reflects the live publishing state.
class SensorToggleBar extends StatelessWidget {
  const SensorToggleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SensorChip(
            icon: Icons.mic,
            label: 'Voice',
            on: state.voiceEnabled,
            onTap: () => state.toggleVoice(!state.voiceEnabled),
          ),
          const SizedBox(width: 8),
          _SensorChip(
            icon: Icons.videocam,
            label: 'Camera',
            on: state.webrtc.isActive,
            onTap: () => state.toggleCamera(!state.webrtc.isActive),
          ),
          const SizedBox(width: 8),
          _SensorChip(
            icon: Icons.threed_rotation,
            label: 'IMU',
            on: state.sensors.imuOn,
            onTap: () => state.toggleImu(!state.sensors.imuOn),
          ),
          const SizedBox(width: 8),
          _SensorChip(
            icon: Icons.gps_fixed,
            label: 'GPS',
            on: state.sensors.gpsOn,
            onTap: () => state.toggleGps(!state.sensors.gpsOn),
          ),
        ],
      ),
    );
  }
}

class _SensorChip extends StatelessWidget {
  const _SensorChip({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? Colors.cyan.withOpacity(0.25) : Colors.white10,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: on ? Colors.cyanAccent : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16, color: on ? Colors.cyanAccent : Colors.white38),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: on ? Colors.cyanAccent : Colors.white38)),
          ],
        ),
      ),
    );
  }
}
