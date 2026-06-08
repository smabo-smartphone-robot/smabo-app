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
import '../services/camera_service.dart';
import '../services/sensor_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';

/// Central application state: wires the connections, services and UI together.
///
/// Routing summary:
///   - Drive / arm / ESP32 config → [connections.esp32].
///   - Eye-follow target, speech and sensors → [connections.brain].
class AppState extends ChangeNotifier {
  AppState() {
    connections = ConnectionManager();
    sensors = SensorService(_publishToBrain);
    camera = CameraService(_publishToBrain);
    speech = SpeechService();
    tts = TtsService();
  }

  late final ConnectionManager connections;
  late final SensorService sensors;
  late final CameraService camera;
  late final SpeechService speech;
  late final TtsService tts;

  AppSettings settings = AppSettings();

  AppMode _mode = AppMode.face;
  AppMode get mode => _mode;

  // Whether the non-face overlays (status bar, sensor toggles, settings button,
  // page dots, eye-mode chip, voice text) are shown. On the face screen they
  // auto-hide after [AppSettings.faceAutoHideSeconds] when [faceAutoHide] is on.
  bool _chromeVisible = true;
  bool get chromeVisible => _chromeVisible;
  Timer? _chromeHideTimer;

  // While true, the home PageView does not swipe between modes — set while a
  // controller (e.g. the drive joystick) is being touched so its drag is not
  // stolen as a page swipe.
  bool _pageLocked = false;
  bool get pageLocked => _pageLocked;
  void setPageLocked(bool v) {
    if (_pageLocked == v) return;
    _pageLocked = v;
    notifyListeners();
  }

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

  OdomState? _odom;
  OdomState? get odom => _odom;

  /// Live ESP32 configuration: the last `get_config` snapshot with local edits
  /// overlaid (see [_esp32Pending]).
  Map<String, dynamic>? esp32Config;

  /// Local config edits applied since the last explicit refresh. They are
  /// re-applied on top of any incoming `get_config` so a (possibly stale or
  /// post-reboot) device snapshot does not clobber a just-made change — which
  /// otherwise made edits (e.g. pins) appear to revert.
  final Map<String, dynamic> _esp32Pending = {};

  /// Face appearance and the decoded images per element (null until loaded).
  /// While an expression is being edited in the settings screen, [_previewConfig]
  /// (live, unsaved) takes precedence so the preview and its images reflect the
  /// in-progress edit; otherwise the active expression's config is shown.
  FaceConfig get faceConfig =>
      _previewConfig ?? settings.faceConfig;
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
  WsStatus _prevEsp32Status = WsStatus.disconnected;
  WsStatus _prevBrainStatus = WsStatus.disconnected;

  final List<StreamSubscription> _subs = [];

  // ------------------------------------------------------------------ init
  Future<void> init() async {
    settings = await AppSettings.load();
    await tts.init(settings.ttsLanguage);

    // ESP32 inbound: odom, joint_states, config, notices.
    _subs.add(connections.esp32.messages.listen(_onEsp32Message));
    _subs.add(connections.esp32.statusStream
        .listen((s) => _onConnStatus('ESP32', s, isEsp32: true)));
    _subs.add(connections.esp32.notices.listen(_addLog));

    // brain inbound: look_at (eye follow), speech/say (TTS).
    _subs.add(connections.brain.messages.listen(_onBrainMessage));
    _subs.add(connections.brain.statusStream
        .listen((s) => _onConnStatus('Brain', s, isEsp32: false)));
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
      // The eyes react (colour) on wake, but the overlays stay hidden — voice
      // detection must not re-show the non-face UI.
      notifyListeners();
    }));

    connections.applySettings(settings);
    await _initVoice();
    _applyDefaultSensors();
    _refreshChrome(); // arm auto-hide (starts on the face screen)
    notifyListeners();
    _syncFaceImages(); // load any custom face images in the background
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

  /// Turn the voice-recognition feature on or off. When off, the STT loop is
  /// stopped (no wake listening, no "speak to me" prompt).
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

  void _applyDefaultSensors() {
    if (settings.imuEnabled) sensors.startImu(rateHz: settings.imuRateHz);
    if (settings.gpsEnabled) sensors.startGps();
    if (settings.cameraEnabled) camera.start(settings);
  }

  // --------------------------------------------------------------- routing
  void _publishToBrain(String topic, Map<String, dynamic> msg) {
    connections.brain.publish(topic, msg);
  }

  void _onEsp32Message(WireMessage m) {
    switch (m.topic) {
      case RosTopics.odom:
        final o = RosMessages.parseOdom(m.msg);
        if (o != null) {
          _odom = o;
          notifyListeners();
        }
        break;
      case '__config__':
        // Overlay any pending local edits so they survive the refresh.
        esp32Config = _deepMerge(m.msg, _esp32Pending);
        notifyListeners();
        break;
      default:
        break;
    }
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
        if (text != null) tts.speak(text);
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
      default:
        break;
    }
  }

  void _onSpeechCommand(String command) {
    _addLog('🎤 Recognized: $command');
    // Recognized speech → std_msgs/String on /speech/recognized (brain device).
    connections.brain.publish(RosTopics.speechRecognized, RosMessages.string(command));
    notifyListeners();
  }

  /// Manually start command capture (skips the wake word) — wired to a tap on
  /// the face as a guaranteed fallback when the spoken trigger misses. No-op
  /// when the voice feature is disabled.
  void startVoiceCapture() {
    if (!settings.voiceEnabled) return;
    speech.triggerRecognition();
  }

  // ------------------------------------------------------- expressions
  /// Switch the shown expression by id (falls back to the default id, then the
  /// first expression). Persists the choice.
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

  /// Begin editing the expression with [id] in the settings screen: the preview
  /// (and its images) switch to this expression even if it is not active.
  Future<void> beginEditExpression(int id) async {
    _editingExpressionId = id;
    _previewConfig = settings.expressionById(id).config.copy();
    notifyListeners();
    await _syncFaceImages();
  }

  /// Stop editing: drop the preview and revert to the active expression.
  Future<void> endEditExpression() async {
    _editingExpressionId = null;
    _previewConfig = null;
    notifyListeners();
    await _syncFaceImages();
  }

  /// Live in-memory update for the preview (clamped, NOT persisted, no image
  /// reload). Use while dragging a slider; commit with [commitEditExpression].
  void previewFaceConfig(FaceConfig cfg) {
    _previewConfig = cfg.clamped();
    notifyListeners();
  }

  /// Apply (clamped) appearance to the expression being edited, persist it and
  /// (re)load any images.
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

  /// Add a new expression (copied from the default) and start editing it.
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

  /// Duplicate an existing expression as a new entry and start editing it.
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

  /// Remove an expression (never the last one). Repairs the active id and the
  /// current edit target if they pointed at the removed entry.
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

  /// Change an expression's id. Returns an error message if [newId] is invalid
  /// or already used, otherwise null on success. Keeps the active/editing ids
  /// pointing at the same expression.
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

  /// Re-add any built-in template missing by id (does not overwrite edits to
  /// templates the user has kept).
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

  /// Decoded element images for one eye ('L' or 'R'), keyed by slot
  /// ('sclera'/'iris'/'pupil'/'highlight') for [EyePainter].
  Map<String, ui.Image?> eyeImages(String side) {
    final out = <String, ui.Image?>{};
    for (final slot in EyeAppearance.slots) {
      out[slot] = faceImages['$side:$slot'];
    }
    return out;
  }

  /// Image paths the active/preview face needs, keyed for [faceImages]:
  /// 'background' (shared) and per eye as `L:slot` / `R:slot`.
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

  /// Load/unload the decoded images to match the current config paths.
  Future<void> _syncFaceImages() async {
    final paths = _faceImagePaths();
    // Drop any keys no longer present (e.g. shape changed away from round).
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
  /// Show the overlays and (re)arm the auto-hide timer. Called on interaction.
  void pokeChrome() {
    if (!_chromeVisible) {
      _chromeVisible = true;
      notifyListeners();
    }
    _scheduleChromeHide();
  }

  void _scheduleChromeHide() {
    _chromeHideTimer?.cancel();
    // Auto-hide applies on every mode (face, drive, arm) when enabled.
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

  /// Re-evaluate overlay visibility for the current settings: arm the auto-hide
  /// timer when enabled, otherwise keep the overlays shown.
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
  void setMode(AppMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    _refreshChrome();
  }

  void setEyeMode(EyeMode m) {
    _eyeMode = m;
    if (m == EyeMode.follow) {
      // Subscribe so a rosbridge_suite server starts forwarding /look_at.
      connections.brain.subscribe(RosTopics.lookAt, RosTypes.poseStamped);
    }
    notifyListeners();
  }

  // --------------------------------------------------------- drive / arm
  /// Send a `geometry_msgs/Twist` to the ESP32 (mobile robot controller).
  void sendCmdVel(double linearX, double angularZ) {
    connections.esp32.publish(RosTopics.cmdVel, RosMessages.twist(linearX, angularZ));
  }

  /// Send a single-point `trajectory_msgs/JointTrajectory` to the ESP32.
  void sendArmCommand(List<String> joints, List<double> positionsRad,
      {double timeFromStart = 0.5}) {
    connections.esp32.publish(
      RosTopics.servoCommand,
      RosMessages.jointTrajectory(joints, positionsRad,
          timeFromStart: timeFromStart),
    );
  }

  // ----------------------------------------------------------- ESP32 config
  /// Request the device config. [fresh] = true clears pending local edits so
  /// the device's real values are shown (used by the explicit "Get config");
  /// the automatic fetch keeps pending edits so they are not clobbered.
  void requestEsp32Config({bool fresh = false}) {
    if (fresh) _esp32Pending.clear();
    connections.esp32.sendOp({'op': 'get_config'});
  }

  void _mergePending(Map<String, dynamic> patch) {
    final merged = _deepMerge(_esp32Pending, patch);
    _esp32Pending
      ..clear()
      ..addAll(merged);
  }

  void setEsp32Config(Map<String, dynamic> patch) {
    connections.esp32.sendOp({'op': 'set_config', 'config': patch});
    // The ESP32 does not echo the updated config back, so mirror the change
    // locally (deep-merge) AND remember it as pending, so a later get_config
    // (e.g. after a pin change reboots the board) does not revert the edit.
    _mergePending(patch);
    if (esp32Config != null) {
      esp32Config = _deepMerge(esp32Config!, patch);
    }
    notifyListeners();
  }

  void setEsp32Modes(Map<String, dynamic> modes) {
    connections.esp32.sendOp({'op': 'set_mode', 'modes': modes});
    _mergePending({'modes': modes});
    if (esp32Config != null) {
      esp32Config = _deepMerge(esp32Config!, {'modes': modes});
    }
    notifyListeners();
  }

  // -- batched pin/bus/WiFi edits (each would reboot the ESP32; collect them
  //    so they can be applied together with a single reboot) ----------------
  /// Staged advanced (pin/bus/WiFi) edits not yet sent to the device.
  final Map<String, dynamic> esp32AdvancedStage = {};
  bool get hasEsp32AdvancedStage => esp32AdvancedStage.isNotEmpty;

  /// Stage one advanced edit (deep-merged) without sending it.
  void stageEsp32Advanced(Map<String, dynamic> patch) {
    final merged = _deepMerge(esp32AdvancedStage, patch);
    esp32AdvancedStage
      ..clear()
      ..addAll(merged);
    notifyListeners();
  }

  /// Send all staged advanced edits in ONE `set_config` — the ESP32 reboots
  /// once to apply them together.
  void applyEsp32Advanced() {
    if (esp32AdvancedStage.isEmpty) return;
    setEsp32Config(Map<String, dynamic>.from(esp32AdvancedStage));
    esp32AdvancedStage.clear();
    notifyListeners();
  }

  void discardEsp32Advanced() {
    if (esp32AdvancedStage.isEmpty) return;
    esp32AdvancedStage.clear();
    notifyListeners();
  }

  /// The staged value at a nested path, or null if not staged.
  dynamic esp32StagedAt(List<String> path) {
    dynamic node = esp32AdvancedStage;
    for (final k in path) {
      if (node is Map && node.containsKey(k)) {
        node = node[k];
      } else {
        return null;
      }
    }
    return node;
  }

  /// Add a servo joint (`servos.joints.<name>`) with a default spec. The ESP32
  /// restarts the servo subsystem to apply it (per DESIGN.md).
  void addEsp32Joint(String name) {
    final spec = <String, dynamic>{
      'channel': _nextFreeServoChannel(),
      'min_angle': -90,
      'max_angle': 90,
      'min_us': 500,
      'max_us': 2500,
      'init_angle': 0,
      'max_speed': 90,
    };
    setEsp32Config({
      'servos': {
        'joints': {name: spec}
      }
    });
  }

  /// Remove a servo joint. Sends the joint as `null` (the DESIGN.md deletion
  /// encoding) and drops it from the local config so the editor updates.
  void removeEsp32Joint(String name) {
    connections.esp32.sendOp({
      'op': 'set_config',
      'config': {
        'servos': {
          'joints': {name: null}
        }
      }
    });
    final servos = (esp32Config?['servos'] as Map?)?.cast<String, dynamic>();
    final joints = (servos?['joints'] as Map?)?.cast<String, dynamic>();
    if (joints != null) {
      joints.remove(name);
      notifyListeners();
    }
  }

  // ---- random-motion groups (manual vs auto assignment is group membership)
  /// Current `servos.random_groups` as a mutable list of maps.
  List<Map<String, dynamic>> esp32RandomGroups() {
    final g = (esp32Config?['servos'] as Map?)?['random_groups'];
    if (g is List) {
      return [
        for (final e in g)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    }
    return [];
  }

  /// The group a joint belongs to, or null if it is manual (no group).
  String? esp32JointGroup(String joint) {
    for (final g in esp32RandomGroups()) {
      final js = (g['joints'] as List?)?.map((e) => '$e') ?? const [];
      if (js.contains(joint)) return g['name']?.toString();
    }
    return null;
  }

  /// Replace the whole random_groups list (it is a List, so it is sent — and
  /// merged — wholesale).
  void _setEsp32RandomGroups(List<Map<String, dynamic>> groups) {
    setEsp32Config({
      'servos': {'random_groups': groups}
    });
  }

  /// Move [joint] into [groupName] (creating the group if needed), or make it
  /// manual when [groupName] is null. A joint lives in at most one group.
  void assignJointMotion(String joint, String? groupName) {
    final groups = <Map<String, dynamic>>[];
    var placed = false;
    for (final g in esp32RandomGroups()) {
      final name = g['name']?.toString();
      final js = <String>[
        for (final j in (g['joints'] as List?) ?? const []) '$j',
      ]..remove(joint);
      if (name == groupName) {
        js.add(joint);
        placed = true;
      }
      groups.add({
        'name': name,
        'joints': js,
        'interval': g['interval'] ?? [1.0, 3.0],
      });
    }
    if (groupName != null && !placed) {
      groups.add({
        'name': groupName,
        'joints': [joint],
        'interval': [1.0, 3.0],
      });
    }
    _setEsp32RandomGroups(groups);
  }

  void addEsp32RandomGroup(String name) {
    if (esp32RandomGroups().any((g) => g['name'] == name)) return;
    final groups = esp32RandomGroups()
      ..add({'name': name, 'joints': <String>[], 'interval': [1.0, 3.0]});
    _setEsp32RandomGroups(groups);
  }

  void removeEsp32RandomGroup(String name) {
    final groups = [
      for (final g in esp32RandomGroups())
        if (g['name'] != name) g,
    ];
    _setEsp32RandomGroups(groups);
  }

  void setEsp32GroupInterval(String name, double lo, double hi) {
    setEsp32GroupParam(name, 'interval', [lo, hi]);
  }

  /// Set one key on a named random group (e.g. lifelike-motion tuning) and
  /// resend the whole list (lists are replaced, not merged).
  void setEsp32GroupParam(String name, String key, dynamic value) {
    final groups = [
      for (final g in esp32RandomGroups())
        if (g['name'] == name)
          {...g, key: value}
        else
          g,
    ];
    _setEsp32RandomGroups(groups);
  }

  /// Servo joint names in the app's preferred display order: saved order first
  /// (filtered to existing joints), then any remaining joints appended.
  List<String> orderedServoNames() {
    final joints =
        ((esp32Config?['servos'] as Map?)?['joints'] as Map?)?.keys ?? const [];
    final all = [for (final k in joints) '$k'];
    final out = <String>[];
    for (final n in settings.servoOrder) {
      if (all.contains(n)) out.add(n);
    }
    for (final n in all) {
      if (!out.contains(n)) out.add(n);
    }
    return out;
  }

  /// Move a servo up (delta -1) or down (delta +1) in the display order.
  void moveServo(String name, int delta) {
    final order = orderedServoNames();
    final i = order.indexOf(name);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return;
    final tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
    settings.servoOrder = order;
    settings.save();
    notifyListeners();
  }

  int _nextFreeServoChannel() {
    final joints =
        ((esp32Config?['servos'] as Map?)?['joints'] as Map?) ?? const {};
    var maxCh = -1;
    joints.forEach((_, spec) {
      final c = spec is Map ? spec['channel'] : null;
      if (c is num && c.toInt() > maxCh) maxCh = c.toInt();
    });
    return (maxCh + 1).clamp(0, 15);
  }

  /// Recursively merge [override] onto [base] (mirrors the firmware's merge).
  /// Non-map values (including lists) replace wholesale.
  Map<String, dynamic> _deepMerge(
      Map<String, dynamic> base, Map<String, dynamic> override) {
    final out = Map<String, dynamic>.from(base);
    override.forEach((k, v) {
      final b = out[k];
      if (b is Map && v is Map) {
        out[k] = _deepMerge(
            b.cast<String, dynamic>(), v.cast<String, dynamic>());
      } else {
        out[k] = v;
      }
    });
    return out;
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

  /// Switch the camera lens (front/back). Restarts the camera if it is live so
  /// the new lens takes effect.
  Future<void> setCameraFront(bool front) async {
    if (settings.cameraFront == front) return;
    settings.cameraFront = front;
    await settings.save();
    final wasStreaming = camera.isStreaming;
    await camera.dispose(); // drop the controller so the new lens is picked
    if (wasStreaming) await camera.start(settings);
    notifyListeners();
  }

  Future<void> toggleCamera(bool on) async {
    if (on) {
      final ok = await camera.start(settings);
      settings.cameraEnabled = ok;
      if (!ok) _addLog('⚠️ Could not start the camera');
    } else {
      await camera.stop();
      settings.cameraEnabled = false;
    }
    settings.save();
    notifyListeners();
  }

  // ------------------------------------------------------------- settings
  Future<void> updateSettings(AppSettings newSettings) async {
    final reconnect = newSettings.esp32Url != settings.esp32Url ||
        newSettings.brainUrl != settings.brainUrl;
    settings = newSettings;
    await settings.save();
    await tts.setLanguage(settings.ttsLanguage);
    speech.updateConfig(
      wakeWord: settings.wakeWord,
      localeId: settings.sttLocaleId,
    );
    if (reconnect) connections.applySettings(settings);
    _refreshChrome(); // apply changed auto-hide preference
    notifyListeners();
  }

  // ------------------------------------------------- connection events
  /// Detect connect/disconnect transitions and emit a one-line notice for the
  /// UI (plus the log). Reliable now that "connected" is set only once the
  /// socket is actually open.
  void _onConnStatus(String label, WsStatus s, {required bool isEsp32}) {
    final prev = isEsp32 ? _prevEsp32Status : _prevBrainStatus;
    if (s != prev) {
      if (s == WsStatus.connected) {
        final msg = '$label connected';
        _addLog('🔌 $msg');
        if (!_connEventController.isClosed) _connEventController.add(msg);
        // Subscribe so a rosbridge_suite server forwards expression changes.
        if (!isEsp32) {
          connections.brain
              .subscribe(RosTopics.faceExpression, RosTypes.int32);
        }
      } else if (prev == WsStatus.connected &&
          (s == WsStatus.error || s == WsStatus.disconnected)) {
        final msg = '$label disconnected';
        _addLog('🔌 $msg');
        if (!_connEventController.isClosed) _connEventController.add(msg);
      }
    }
    if (isEsp32) {
      _prevEsp32Status = s;
    } else {
      _prevBrainStatus = s;
    }
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
    for (final s in _subs) {
      s.cancel();
    }
    speech.dispose();
    sensors.dispose();
    camera.dispose();
    connections.dispose();
    _connEventController.close();
    super.dispose();
  }
}
