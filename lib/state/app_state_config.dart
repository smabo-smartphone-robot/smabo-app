part of 'app_state.dart';

/// The phone's settings over REST, like the ESP32's: [configServer] serves
/// `GET/POST /config` (port 8081); the brain connection carries the notices
/// smabo-web listens to:
///   /app/phone/config_url  where the API is (on connect and every 5 s)
///   /app/phone/config      the whole tree (on connect and after every change)
extension AppStateConfig on AppState {
  Map<String, dynamic> phoneConfig() {
    final c = phoneConfigToJson(settings, httpPort: configServer.boundPort ?? configServer.port);
    (c['brain'] as Map<String, dynamic>).addAll(pairing.status());
    return c;
  }

  /// Pair with the brain using an invite code from smabo-web (Settings, or
  /// `{"brain": {"invite": CODE}}` on the REST API): reconnect and show it.
  void pairWithBrain(String code) {
    pairing.setInvite(code);
    if (pairing.invite.isEmpty) return;
    _addLog('🔒 Pairing with the brain…');
    connections.brain.retryNow();
    _notify();
  }

  /// Forget the brain's token (Settings → Brain → Unpair).
  Future<void> unpairBrain() async {
    await pairing.forget();
    _addLog('🔒 Forgot the pairing with the brain');
    connections.brain.retryNow();
    _notify();
  }

  /// Apply a partial settings tree (POST /config) through the same setters the
  /// settings screen uses. Returns the paths that were ignored.
  Future<List<String>> applyPhoneConfig(Map<String, dynamic> patch) async {
    final invite = takeInvite(patch);
    if (invite != null) pairWithBrain(invite);
    final p = parsePhoneConfigPatch(patch,
        expressionNames: [for (final e in settings.expressions) e.name]);
    _configBatch++;
    try {
      for (final MapEntry(key: path, value: v) in p.values.entries) {
        switch (path) {
          case 'sensors.imu.enabled':
            if (v != settings.imuEnabled) toggleImu(v as bool);
          case 'sensors.imu.rate_hz':
            await setImuRate(v as int);
          case 'sensors.gps.enabled':
            if (v != settings.gpsEnabled) await toggleGps(v as bool);
          case 'sensors.camera.enabled':
            if (v != settings.cameraEnabled) await toggleCamera(v as bool);
          case 'sensors.camera.front':
            await setCameraFront(v as bool);
          case 'voice.enabled':
            if (v != settings.voiceEnabled) await toggleVoice(v as bool);
          case 'voice.wake_word':
            await setWakeWord(v as String);
          case 'voice.stt_locale':
            await setSttLocale(v as String);
          case 'speech.tts':
            if (v != settings.ttsEnabled) await toggleTts(v as bool);
          case 'speech.tts_language':
            await setTtsLanguage(v as String);
          case 'speech.bubble':
            if (v != settings.speechBubbleEnabled) await toggleSpeechBubble(v as bool);
          case 'speech.ignore_repeated':
            if (v != settings.ignoreRepeatedSpeech) await toggleIgnoreRepeatedSpeech(v as bool);
          case 'face.auto_hide':
            await setFaceAutoHide(v as bool);
          case 'face.auto_hide_seconds':
            await setFaceAutoHideSeconds(v as int);
          case 'face.expression':
            await setActiveExpressionByName(v as String);
        }
      }
    } finally {
      _configBatch--;
    }
    if (p.values.isNotEmpty) {
      _addLog('⚙️ Settings changed over REST: ${p.values.keys.join(', ')}');
      _publishPhoneConfig();
    }
    return p.ignored;
  }

  /// Persist the settings, then tell smabo-web (one notice per REST patch).
  Future<void> _saveSettings() async {
    await settings.save();
    if (_configBatch == 0) _publishPhoneConfig();
  }

  /// An expression was edited over REST: save, tell smabo-web, redraw (and
  /// refresh the settings screen's preview if it has this one open).
  Future<void> _expressionChanged(int id) async {
    if (_editingExpressionId == id) _previewConfig = settings.expressionById(id).config.copy();
    await _saveSettings();
    _notify();
  }

  void _publishPhoneConfig() {
    if (connections.brain.status != WsStatus.connected) return;
    _publishToBrain(RosTopics.phoneConfig, {'data': jsonEncode(phoneConfig())});
  }

  Future<void> _startConfigServer() async {
    if (await configServer.start()) {
      _addLog('⚙️ Settings REST API on port ${configServer.boundPort}');
    } else {
      _addLog('⚠️ Settings REST API: port ${configServer.port} is in use');
    }
  }

  /// After (re)connecting: find our address on the brain's network, then
  /// announce the API now and every 5 s, and send the settings once.
  Future<void> _announceConfig() async {
    _publishPhoneConfig();
    _configUrlTimer?.cancel();
    _configUrlTimer = Timer.periodic(const Duration(seconds: 5), (_) => _publishConfigUrl());
    _configUrl ??= await _localUrl();
    _publishConfigUrl();
  }

  void _publishConfigUrl() {
    final url = _configUrl;
    final port = configServer.boundPort;
    if (url == null || port == null || connections.brain.status != WsStatus.connected) return;
    _publishToBrain(RosTopics.phoneConfigUrl, {'data': url});
  }

  /// `http://<our address toward the brain>:<port>`: the interface that
  /// actually reaches the brain (Wi-Fi, not cellular).
  Future<String?> _localUrl() async {
    final port = configServer.boundPort;
    if (port == null) return null;
    try {
      final s = await Socket.connect(settings.brainHost, settings.brainPort,
          timeout: const Duration(seconds: 3));
      final a = s.address;
      s.destroy();
      final host = a.type == InternetAddressType.IPv6 ? '[${a.address}]' : a.address;
      return 'http://$host:$port';
    } catch (_) {
      return null;
    }
  }
}

/// `/face/...` on the settings API: the expressions, edited from smabo-web.
class _FaceRest implements FaceApi {
  _FaceRest(this.app);
  final AppState app;

  @override
  Map<String, dynamic> schema() => faceSchemaJson();

  @override
  Map<String, dynamic> list() => {
        'active': app.settings.activeExpressionId,
        'expressions': [for (final x in app.settings.expressions) expressionToJson(x)],
      };

  FaceExpression? _find(int id) => app.settings.expressions.where((e) => e.id == id).firstOrNull;

  @override
  Future<List<String>?> patch(int id, Map<String, dynamic> patch) async {
    final x = _find(id);
    if (x == null) return null;
    final edited = x.copy();
    final ignored = applyExpressionPatch(edited, patch, taken: app._namesExcept(id));
    x
      ..name = edited.name
      ..config = edited.config.clamped();
    await app._expressionChanged(id);
    return ignored;
  }

  @override
  Future<int?> add({int? copyOf, Map<String, dynamic> patch = const {}}) async {
    final src = copyOf == null ? null : _find(copyOf);
    if (copyOf != null && src == null) return null;
    final id = app._nextExpressionId();
    final taken = app._namesExcept(null);
    final x = FaceExpression(
        id: id,
        name: uniqueExpressionName(src == null ? 'Expression' : '${src.name} (copy)', taken),
        config: src?.config.copy() ?? FaceConfig());
    applyExpressionPatch(x, patch, taken: taken);
    x.config = x.config.clamped();
    app.settings.expressions.add(x);
    await app._expressionChanged(id);
    return id;
  }

  @override
  Future<String?> delete(int id) async {
    if (_find(id) == null) return 'no such expression';
    if (app.settings.expressions.length <= 1) return 'the last expression cannot be deleted';
    await app.deleteExpression(id);
    return null;
  }

  /// Drawn from the live config while the phone's editor has [id] open.
  @override
  Future<List<int>?> preview(int id, int width, int height) async {
    final x = _find(id);
    if (x == null) return null;
    final fc = app._editingExpressionId == id ? app.faceConfig : x.config;
    return renderFacePng(fc, width, height);
  }
}
