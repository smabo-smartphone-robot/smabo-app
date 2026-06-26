import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/models/app_settings.dart';

/// Streams the phone camera to **smabo-brain** over WebRTC. The brain is the
/// single peer: it pulls frames for vision detection and relays the video on to
/// smabo-web preview clients. Signaling rides the brain WebSocket.
///
/// Flow:
///   1. [start] opens the camera via getUserMedia and sends an offer to brain.
///   2. Brain (aiortc) answers → app → [handleAnswer].
///   3. The app trickles its ICE candidates via `/webrtc/app_ice`; the brain's
///      candidates are bundled in the answer SDP (aiortc is non-trickle), so the
///      app has no separate incoming candidates to apply.
///   4. P2P video is established: phone → brain (H.264).
class WebRtcService {
  WebRtcService(this._publish);

  final void Function(String topic, Map<String, dynamic> msg) _publish;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  bool get isActive => _localStream != null;

  Future<void> start(AppSettings settings) async {
    await _teardown();
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': {
          'facingMode': settings.cameraFront ? 'user' : 'environment',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
        },
        'audio': false,
      });
      await _buildConnection();
    } catch (e) {
      debugPrint('WebRTC: start failed — $e');
    }
  }

  /// Re-send an offer to the brain (e.g. after the brain reconnects) while the
  /// camera is already running.
  Future<void> recreateOffer() async {
    if (_localStream == null) return;
    await _pc?.close();
    _pc = null;
    await _buildConnection();
  }

  Future<void> _buildConnection() async {
    final stream = _localStream;
    if (stream == null) return;

    _pc = await createPeerConnection({
      'iceServers': [],       // local WiFi — no STUN/TURN needed
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = (c) {
      if (c.candidate != null) {
        _publish('/webrtc/app_ice', {
          'data': jsonEncode({
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          }),
        });
      }
    };

    _pc!.onIceConnectionState = (s) => debugPrint('WebRTC ICE: $s');

    for (final track in stream.getTracks()) {
      await _pc!.addTrack(track, stream);
    }

    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    _publish('/webrtc/offer', {
      'data': jsonEncode({'sdp': offer.sdp, 'type': offer.type}),
    });
    debugPrint('WebRTC: offer sent to brain');
  }

  Future<void> handleAnswer(Map<String, dynamic> msg) async {
    try {
      final data = jsonDecode(msg['data'] as String) as Map<String, dynamic>;
      await _pc?.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, data['type'] as String),
      );
      debugPrint('WebRTC: answer applied');
    } catch (e) {
      debugPrint('WebRTC: handleAnswer failed — $e');
    }
  }

  Future<void> stop() async => _teardown();

  Future<void> dispose() async => _teardown();

  Future<void> _teardown() async {
    await _pc?.close();
    _pc = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    await _localStream?.dispose();
    _localStream = null;
  }
}
