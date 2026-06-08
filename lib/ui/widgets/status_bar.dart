import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/wire/ws_client.dart';
import '../../services/speech_service.dart';
import '../../state/app_state.dart';

/// Slim top overlay: per-endpoint connection dots and a voice indicator.
/// Visible over every page.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _Dot(label: 'ESP32', status: state.connections.esp32.status),
          const SizedBox(width: 12),
          _Dot(label: 'Brain', status: state.connections.brain.status),
          const Spacer(),
          _VoiceIndicator(voiceState: state.voiceState),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.label, required this.status});
  final String label;
  final WsStatus status;

  Color get _color {
    switch (status) {
      case WsStatus.connected:
        return Colors.greenAccent;
      case WsStatus.connecting:
        return Colors.amber;
      case WsStatus.error:
        return Colors.redAccent;
      case WsStatus.disconnected:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

class _VoiceIndicator extends StatelessWidget {
  const _VoiceIndicator({required this.voiceState});
  final VoiceState voiceState;

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.mic_off;
    Color color = Colors.white24;
    switch (voiceState) {
      case VoiceState.recognizing:
        icon = Icons.mic;
        color = Colors.cyanAccent;
        break;
      case VoiceState.listeningForWake:
        icon = Icons.hearing;
        color = Colors.white54;
        break;
      case VoiceState.idle:
        icon = Icons.mic_off;
        color = Colors.white24;
        break;
    }
    return Icon(icon, color: color, size: 18);
  }
}
