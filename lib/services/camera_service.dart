import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../core/models/app_settings.dart';
import '../core/wire/ros_compat.dart';

/// Captures camera frames and publishes them to the brain device as either
/// `sensor_msgs/CompressedImage` (JPEG) or `sensor_msgs/Image` (raw), selected
/// by [AppSettings.cameraFormat].
///
/// Frames are throttled to [AppSettings.cameraFps]. Compressed mode takes a
/// JPEG still per tick (simple, bandwidth-friendly). Raw mode uses the image
/// stream and forwards the luminance plane as `mono8` to keep the payload
/// sane — full RGB raw over a phone WebSocket is impractical.
class CameraService {
  CameraService(this._publish);

  final void Function(String topic, Map<String, dynamic> msg) _publish;

  CameraController? _controller;
  bool _streaming = false;
  bool get isStreaming => _streaming;

  bool _front = true; // desired lens (set from settings on start)

  Timer? _jpegTimer;
  DateTime _lastRawFrame = DateTime.fromMillisecondsSinceEpoch(0);

  Future<bool> _ensureController() async {
    if (_controller != null) return true;
    final cameras = await availableCameras();
    if (cameras.isEmpty) return false;
    final want =
        _front ? CameraLensDirection.front : CameraLensDirection.back;
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == want,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    _controller = controller;
    return true;
  }

  /// Live preview controller for on-screen display (null until started).
  CameraController? get controller => _controller;

  Future<bool> start(AppSettings settings) async {
    _front = settings.cameraFront;
    if (_streaming) return true;
    if (!await _ensureController()) return false;
    _streaming = true;
    if (settings.cameraFormat == CameraFormat.compressed) {
      _startJpeg(settings);
    } else {
      await _startRaw(settings);
    }
    return true;
  }

  void _startJpeg(AppSettings settings) {
    final period = Duration(milliseconds: (1000 / settings.cameraFps).round());
    _jpegTimer = Timer.periodic(period, (_) => _captureJpeg());
  }

  Future<void> _captureJpeg() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    try {
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      _publish(
        RosTopics.cameraImage,
        RosMessages.compressedImage(base64Encode(bytes)),
      );
    } catch (_) {
      // Skip this frame on transient capture errors.
    }
  }

  Future<void> _startRaw(AppSettings settings) async {
    final minGap = Duration(milliseconds: (1000 / settings.cameraFps).round());
    await _controller!.startImageStream((CameraImage image) {
      final now = DateTime.now();
      if (now.difference(_lastRawFrame) < minGap) return;
      _lastRawFrame = now;
      _publishRaw(image);
    });
  }

  void _publishRaw(CameraImage image) {
    // Forward the Y (luminance) plane as mono8 — compact and sufficient for
    // most robotics use; the brain device can request compressed mode for color.
    final yPlane = image.planes.first;
    final width = image.width;
    final height = image.height;
    final bytesPerRow = yPlane.bytesPerRow;

    Uint8List data;
    if (bytesPerRow == width) {
      data = yPlane.bytes;
    } else {
      // Strip row padding.
      data = Uint8List(width * height);
      for (var row = 0; row < height; row++) {
        final src = row * bytesPerRow;
        data.setRange(row * width, row * width + width,
            yPlane.bytes.sublist(src, src + width));
      }
    }
    _publish(
      RosTopics.cameraImageRaw,
      RosMessages.rawImage(
        width: width,
        height: height,
        encoding: 'mono8',
        base64Data: base64Encode(data),
      ),
    );
  }

  Future<void> stop() async {
    _streaming = false;
    _jpegTimer?.cancel();
    _jpegTimer = null;
    final c = _controller;
    if (c != null && c.value.isStreamingImages) {
      try {
        await c.stopImageStream();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await stop();
    await _controller?.dispose();
    _controller = null;
  }
}
