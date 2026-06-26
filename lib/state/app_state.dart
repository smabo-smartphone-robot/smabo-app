import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/connection/connection_manager.dart';
import '../core/models/app_mode.dart';
import '../core/models/app_settings.dart';
import '../core/models/face_config.dart';
import '../core/models/face_expression.dart';
import '../core/wire/ros_compat.dart';
import '../core/wire/ws_client.dart';
import '../services/sensor_service.dart';
import '../services/webrtc_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';

/// Central application state: wires the brain connection, services and UI.
///
/// Routing summary:
///   - Eye-follow target, speech and sensors → [connections.brain].
class AppState extends ChangeNotifier {
  AppState() {
    connections = ConnectionManager();
    sensors = SensorService(_publishToBrain);
    webrtc = WebRtcService(_publishToBrain);
    speech = SpeechService();
    tts = TtsService();
  }

  late final ConnectionManager connections;
  late final SensorService sensors;
  late final WebRtcService webrtc;
  late final SpeechService speech;
  late final TtsService tts;

  AppSettings settings = AppSettings();

  // Whether the non-face overlays (status bar, sensor toggles, settings button,
  // eye-mode chip, voice text) are shown. They auto-hide after
  // [AppSettings.faceAutoHideSeconds] when [faceAutoHide] is on.
  bool _chromeVisible = true;
  bool get chromeVisible => _chromeVisible;
  Timer? _chromeHideTimer;

  EyeMode _eyeMode = EyeMode.random;
  EyeMode get eyeMode => _eyeMode;

  GazeTarget? _gazeTarget;
  GazeTarget? get gazeTarget => _gazeTarget;

  VoiceState _voiceState = VoiceState.idle;
  VoiceState get voiceState => _voiceState;

  /// Increments once per wake-word detection — a pulse the face uses to hold
  /// its reaction for a fixed time, independent of how briefly recognition runs.
  int _wakeCount = 0;
  int get wakeCount => _wakeCount;
  String _lastPartial = '';
  String get lastPartial => _lastPartial;

  /// Text currently shown in the face speech bubble (empty = no bubble). Set
  /// from `/speech/say` when [AppSettings.speechBubbleEnabled] is on, and
  /// cleared automatically after a short, length-based hold.
  String _bubbleText = '';
  String get bubbleText => _bubbleText;
  Timer? _bubbleTimer;

  /// Last text spoken/shown from `/speech/say`, used to drop consecutive
  /// duplicates when [AppSettings.ignoreRepeatedSpeech] is on.
  String _lastSpokenText = '';

  /// Face appearance and the decoded images per element (null until loaded).
  /// While an expression is being edited in the settings screen, [_previewConfig]
  /// (live, unsaved) takes precedence so the preview and its images reflect the
  /// in-progress edit; otherwise the active expression's config is shown.
  FaceConfig get faceConfig => _previewConfig ?? settings.faceConfig;
  final Map<String, ui.Image?> faceImages = {};
  final Map<String, String> _loadedImagePaths = {};

  // Expression editing (settings screen): which expression is open and its
  // live, not-yet-committed config.
  int? _editingExpressionId;
  FaceConfig? _previewConfig;

  List<FaceExpression> get expressions => settings.expressions;
  int get activeExpressionId => settings.activeExpressionId;
  int? get editingExpressionId => _editingExpressionId;
  FaceExpression expressionById(int id) => settings.expressionById(id);

  final List<String> _log = [];
  List<String> get log => List.unmodifiable(_log);

  // Transient connect/disconnect notifications for the UI to display.
  final _connEventController = StreamController<String>.broadcast();
  Stream<String> get connectionEvents => _connEventController.stream;
  WsStatus _prevBrainStatus = WsStatus.disconnected;

  final List<StreamSubscription> _subs = [];

  // ------------------------------------------------------------------ init
  Future<void> init() async {
    settings = await AppSettings.load();
    await tts.init(settings.ttsLanguage);

    // Brain inbound: look_at (eye follow), speech/say (TTS), expression.
    _subs.add(connections.brain.messages.listen(_onBrainMessage));
    _subs.add(connections.brain.statusStream.listen(_onConnStatus));
    _subs.add(connections.brain.notices.listen(_addLog));

    // Speech pipeline.
    _subs.add(speech.stateStream.listen((s) {
      _voiceState = s;
      notifyListeners();
    }));
    _subs.add(speech.onPartial.listen((p) {
      _lastPartial = p;
      notifyListeners();
    }));
    _subs.add(speech.onCommand.listen(_onSpeechCommand));
    _subs.add(speech.debug.listen((m) => _addLog('🗣 $m')));
    _subs.add(speech.onWake.listen((_) {
      _wakeCount++;
      notifyListeners();
    }));

    connections.applySettings(settings);
    await _initVoice();
    _applyDefaultSensors();
    _refreshChrome();
    notifyListeners();
    _syncFaceImages();
  }

  Future<void> _initVoice() async {
    if (settings.voiceEnabled) await _enableVoice();
  }

  /// Lazily initialise STT (requesting the mic permission only when voice is
  /// actually wanted) and start the wake-word loop.
  Future<void> _enableVoice() async {
    if (!speech.isAvailable) {
      final ok = await speech.init(
        wakeWord: settings.wakeWord,
        localeId: settings.sttLocaleId,
      );
      if (!ok) return;
    }
    await speech.start();
  }

  bool get voiceEnabled => settings.voiceEnabled;

  Future<void> toggleVoice(bool on) async {
    settings.voiceEnabled = on;
    await settings.save();
    if (on) {
      await _enableVoice();
    } else {
      await speech.stop();
    }
    notifyListeners();
  }

  bool get ttsEnabled => settings.ttsEnabled;
  bool get speechBubbleEnabled => settings.speechBubbleEnabled;

  Future<void> toggleTts(bool on) async {
    settings.ttsEnabled = on;
    await settings.save();
    if (!on) await tts.stop();
    notifyListeners();
  }

  Future<void> toggleSpeechBubble(bool on) async {
    settings.speechBubbleEnabled = on;
    await settings.save();
    if (!on) _clearBubble();
    notifyListeners();
  }

  Future<void> toggleIgnoreRepeatedSpeech(bool on) async {
    settings.ignoreRepeatedSpeech = on;
    await settings.save();
    notifyListeners();
  }

  void _showBubble(String text) {
    _bubbleText = text.trim();
    _bubbleTimer?.cancel();
    final seconds = (2.5 + _bubbleText.length * 0.18).clamp(2.5, 15.0);
    _bubbleTimer = Timer(
      Duration(milliseconds: (seconds * 1000).round()),
      () {
        _bubbleText = '';
        notifyListeners();
      },
    );
    notifyListeners();
  }

  void _clearBubble() {
    _bubbleTimer?.cancel();
    if (_bubbleText.isNotEmpty) {
      _bubbleText = '';
      notifyListeners();
    }
  }

  void _applyDefaultSensors() {
    if (settings.imuEnabled) sensors.startImu(rateHz: settings.imuRateHz);
    if (settings.gpsEnabled) sensors.startGps();
    if (settings.cameraEnabled) {
      webrtc.start(settings);
    }
  }

  // --------------------------------------------------------------- routing
  /// Source prefix prepended to every app→brain publish. The brain strips it
  /// before re-broadcasting so subscribers see canonical ROS topic names.
  static const _brainTopicPrefix = '/app';

  void _publishToBrain(String topic, Map<String, dynamic> msg) {
    connections.brain.publish('$_brainTopicPrefix$topic', msg);
  }

  void _onBrainMessage(WireMessage m) {
    switch (m.topic) {
      case RosTopics.lookAt:
        final g = RosMessages.parseLookAt(m.msg);
        if (g != null && _eyeMode == EyeMode.follow) {
          _gazeTarget = g;
          notifyListeners();
        }
        break;
      case RosTopics.speechSay:
        final text = RosMessages.parseString(m.msg);
        if (text != null && text.trim().isNotEmpty) {
          // Drop a string identical to the previous one when enabled (e.g. a
          // vision source repeating the same AR/QR text every frame).
          if (settings.ignoreRepeatedSpeech && text == _lastSpokenText) {
            break;
          }
          _lastSpokenText = text;
          if (settings.ttsEnabled) tts.speak(text);
          if (settings.speechBubbleEnabled) _showBubble(text);
        }
        break;
      case RosTopics.faceExpression:
        final id = RosMessages.parseInt32(m.msg);
        if (id != null) {
          if (settings.expressions.any((e) => e.id == id)) {
            setActiveExpression(id);
          } else {
            _addLog('⚠️ Unknown expression id: $id (ignored)');
          }
        }
        break;
      case '/webrtc/answer':
        webrtc.handleAnswer(m.msg);
        break;
      default:
        break;
    }
  }

  void _onSpeechCommand(String command) {
    _addLog('🎤 Recognized: $command');
    _publishToBrain(RosTopics.speechRecognized, RosMessages.string(command));
    notifyListeners();
  }

  /// Manually start command capture (skips the wake word) — wired to a tap on
  /// the face as a guaranteed fallback when the spoken trigger misses.
  void startVoiceCapture() {
    if (!settings.voiceEnabled) return;
    speech.triggerRecognition();
  }

  // ------------------------------------------------------- expressions
  Future<void> setActiveExpression(int id) async {
    final resolved = settings.expressionById(id).id;
    if (settings.activeExpressionId == resolved && _previewConfig == null) {
      return;
    }
    settings.activeExpressionId = resolved;
    await settings.save();
    notifyListeners();
    await _syncFaceImages();
  }

  Future<void> beginEditExpression(int id) async {
    _editingExpressionId = id;
    _previewConfig = settings.expressionById(id).config.copy();
    notifyListeners();
    await _syncFaceImages();
  }

  Future<void> endEditExpression() async {
    _editingExpressionId = null;
    _previewConfig = null;
    notifyListeners();
    await _syncFaceImages();
  }

  void previewFaceConfig(FaceConfig cfg) {
    _previewConfig = cfg.clamped();
    notifyListeners();
  }

  Future<void> commitEditExpression(FaceConfig cfg) async {
    final clamped = cfg.clamped();
    _previewConfig = clamped;
    final id = _editingExpressionId;
    if (id != null) {
      settings.expressionById(id).config = clamped.copy();
      await settings.save();
    }
    notifyListeners();
    await _syncFaceImages();
  }

  Future<int> addExpression() async {
    final id = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: id,
      name: 'Expression $id',
      config: FaceConfig(),
    ));
    await settings.save();
    await beginEditExpression(id);
    return id;
  }

  Future<int> duplicateExpression(int id) async {
    final src = settings.expressionById(id);
    final newId = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: newId,
      name: '${src.name} (copy)',
      config: src.config.copy(),
    ));
    await settings.save();
    await beginEditExpression(newId);
    return newId;
  }

  Future<void> deleteExpression(int id) async {
    if (settings.expressions.length <= 1) return;
    settings.expressions.removeWhere((e) => e.id == id);
    if (!settings.expressions.any((e) => e.id == settings.activeExpressionId)) {
      settings.activeExpressionId = settings.expressions.first.id;
    }
    if (_editingExpressionId == id) {
      _editingExpressionId = null;
      _previewConfig = null;
    }
    await settings.save();
    notifyListeners();
    await _syncFaceImages();
  }

  Future<String?> changeExpressionId(int oldId, int newId) async {
    if (newId == oldId) return null;
    if (newId < 1) return 'ID must be a positive integer';
    if (settings.expressions.any((e) => e.id == newId)) {
      return 'ID $newId is already used';
    }
    final idx = settings.expressions.indexWhere((e) => e.id == oldId);
    if (idx < 0) return 'Expression not found';
    settings.expressions[idx].id = newId;
    if (settings.activeExpressionId == oldId) {
      settings.activeExpressionId = newId;
    }
    if (_editingExpressionId == oldId) _editingExpressionId = newId;
    settings.expressions.sort((a, b) => a.id.compareTo(b.id));
    await settings.save();
    notifyListeners();
    return null;
  }

  Future<void> renameExpression(int id, String name) async {
    settings.expressionById(id).name = name;
    await settings.save();
    notifyListeners();
  }

  Future<void> restoreTemplates() async {
    final present = settings.expressions.map((e) => e.id).toSet();
    for (final t in FaceExpression.templates()) {
      if (!present.contains(t.id)) settings.expressions.add(t);
    }
    await settings.save();
    notifyListeners();
  }

  int _nextExpressionId() {
    var maxId = 0;
    for (final e in settings.expressions) {
      if (e.id > maxId) maxId = e.id;
    }
    return maxId + 1;
  }

  Map<String, ui.Image?> eyeImages(String side) {
    final out = <String, ui.Image?>{};
    for (final slot in EyeAppearance.slots) {
      out[slot] = faceImages['$side:$slot'];
    }
    return out;
  }

  Map<String, String?> _faceImagePaths() {
    final fc = faceConfig;
    final l = fc.displayLeft;
    final r = fc.displayRight;
    final out = <String, String?>{'background': fc.backgroundImage};
    for (final slot in EyeAppearance.slots) {
      out['L:$slot'] = l.imageForSlot(slot);
      out['R:$slot'] = r.imageForSlot(slot);
    }
    return out;
  }

  Future<void> _syncFaceImages() async {
    final paths = _faceImagePaths();
    for (final key in faceImages.keys.toList()) {
      if (!paths.containsKey(key)) {
        faceImages.remove(key);
        _loadedImagePaths.remove(key);
      }
    }
    for (final entry in paths.entries) {
      final key = entry.key;
      final path = entry.value;
      if (path == null) {
        if (faceImages[key] != null || _loadedImagePaths.containsKey(key)) {
          faceImages[key] = null;
          _loadedImagePaths.remove(key);
          notifyListeners();
        }
      } else if (_loadedImagePaths[key] != path) {
        final img = await _loadImage(path);
        faceImages[key] = img;
        _loadedImagePaths[key] = path;
        notifyListeners();
      }
    }
  }

  Future<ui.Image?> _loadImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      _addLog('⚠️ Could not load image: $path');
      return null;
    }
  }

  // ------------------------------------------------------------ chrome (UI)
  void pokeChrome() {
    if (!_chromeVisible) {
      _chromeVisible = true;
      notifyListeners();
    }
    _scheduleChromeHide();
  }

  void _scheduleChromeHide() {
    _chromeHideTimer?.cancel();
    if (settings.faceAutoHide) {
      _chromeHideTimer = Timer(
        Duration(seconds: settings.faceAutoHideSeconds.clamp(1, 3600)),
        () {
          _chromeVisible = false;
          notifyListeners();
        },
      );
    }
  }

  void _refreshChrome() {
    if (settings.faceAutoHide) {
      _scheduleChromeHide();
    } else {
      _chromeHideTimer?.cancel();
      if (!_chromeVisible) {
        _chromeVisible = true;
        notifyListeners();
      }
    }
  }

  // ----------------------------------------------------------------- modes
  void setEyeMode(EyeMode m) {
    _eyeMode = m;
    if (m == EyeMode.follow) {
      connections.brain.subscribe(RosTopics.lookAt, RosTypes.poseStamped);
    }
    notifyListeners();
  }

  // -------------------------------------------------------------- sensors
  void toggleImu(bool on) {
    if (on) {
      sensors.startImu(rateHz: settings.imuRateHz);
    } else {
      sensors.stopImu();
    }
    settings.imuEnabled = on;
    settings.save();
    notifyListeners();
  }

  Future<void> toggleGps(bool on) async {
    if (on) {
      final ok = await sensors.startGps();
      settings.gpsEnabled = ok;
      if (!ok) _addLog('⚠️ GPS: permission or location service disabled');
    } else {
      sensors.stopGps();
      settings.gpsEnabled = false;
    }
    settings.save();
    notifyListeners();
  }

  Future<void> setCameraFront(bool front) async {
    if (settings.cameraFront == front) return;
    settings.cameraFront = front;
    await settings.save();
    final wasActive = webrtc.isActive;
    await webrtc.stop();
    if (wasActive) await webrtc.start(settings);
    notifyListeners();
  }

  Future<void> toggleCamera(bool on) async {
    if (on) {
      await webrtc.start(settings);
      settings.cameraEnabled = true;
    } else {
      await webrtc.stop();
      settings.cameraEnabled = false;
    }
    settings.save();
    notifyListeners();
  }

  // ------------------------------------------------------------- settings
  Future<void> updateSettings(AppSettings newSettings) async {
    final reconnect = newSettings.brainUrl != settings.brainUrl;
    settings = newSettings;
    await settings.save();
    await tts.setLanguage(settings.ttsLanguage);
    speech.updateConfig(
      wakeWord: settings.wakeWord,
      localeId: settings.sttLocaleId,
    );
    if (reconnect) connections.applySettings(settings);
    _refreshChrome();
    notifyListeners();
  }

  // ------------------------------------------------- connection events
  void _onConnStatus(WsStatus s) {
    if (s != _prevBrainStatus) {
      if (s == WsStatus.connected) {
        const msg = 'Brain connected';
        _addLog('🔌 $msg');
        if (!_connEventController.isClosed) _connEventController.add(msg);
        connections.brain.subscribe(RosTopics.faceExpression, RosTypes.int32);
        // Brain restarted/(re)connected: re-send the WebRTC offer so the brain
        // re-establishes the camera peer while the camera is already running.
        if (webrtc.isActive) webrtc.recreateOffer();
      } else if (_prevBrainStatus == WsStatus.connected &&
          (s == WsStatus.error || s == WsStatus.disconnected)) {
        const msg = 'Brain disconnected';
        _addLog('🔌 $msg');
        if (!_connEventController.isClosed) _connEventController.add(msg);
      }
    }
    _prevBrainStatus = s;
    notifyListeners();
  }

  // ------------------------------------------------------------------- log
  void _addLog(String line) {
    _log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (_log.length > 100) _log.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    _chromeHideTimer?.cancel();
    _bubbleTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    speech.dispose();
    sensors.dispose();
    webrtc.dispose();
    connections.dispose();
    _connEventController.close();
    super.dispose();
  }
}
