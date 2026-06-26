import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'face_config.dart';
import 'face_expression.dart';

/// Persistent application settings.
class AppSettings {
  AppSettings({
    this.brainHost = '192.168.4.2',
    this.brainPort = 9090,
    this.cameraFront = true,
    this.imuRateHz = 20,
    this.gpsEnabled = false,
    this.imuEnabled = false,
    this.cameraEnabled = false,
    this.voiceEnabled = true,
    this.wakeWord = 'smabo',
    this.ttsLanguage = 'ja-JP',
    this.sttLocaleId = 'ja_JP',
    this.ttsEnabled = true,
    this.speechBubbleEnabled = true,
    this.ignoreRepeatedSpeech = true,
    this.faceAutoHide = true,
    this.faceAutoHideSeconds = 5,
    this.activeExpressionId = 1,
    List<FaceExpression>? expressions,
  }) : expressions = expressions ?? FaceExpression.templates();

  String brainHost;
  int brainPort;

  bool cameraFront; // true = front (selfie) camera, false = back
  int imuRateHz;

  // Default sensor publish state at launch (each is still toggled live).
  bool gpsEnabled;
  bool imuEnabled;
  bool cameraEnabled;

  bool voiceEnabled;
  String wakeWord;
  String ttsLanguage;
  String sttLocaleId;

  /// On the face screen, read aloud (TTS) text received on `/speech/say`.
  bool ttsEnabled;

  /// On the face screen, show text received on `/speech/say` as a speech bubble.
  bool speechBubbleEnabled;

  /// Ignore a `/speech/say` message whose text is identical to the one that was
  /// just spoken (consecutive duplicates). Useful when a detection-driven source
  /// (e.g. AR/QR vision) repeats the same string every frame.
  bool ignoreRepeatedSpeech;

  /// On the face screen, hide all non-face UI (overlays) after a delay.
  bool faceAutoHide;
  int faceAutoHideSeconds;

  /// Saved facial expressions (each has a stable [FaceExpression.id]).
  List<FaceExpression> expressions;

  /// The currently shown expression (by id). Switchable in settings and via the
  /// `/expression` websocket topic.
  int activeExpressionId;

  /// The active expression's config, or the first available.
  FaceConfig get faceConfig => expressionById(activeExpressionId).config;

  /// Lookup by id, falling back to the first entry when not found.
  FaceExpression expressionById(int id) {
    for (final e in expressions) {
      if (e.id == id) return e;
    }
    return expressions.isNotEmpty
        ? expressions.first
        : FaceExpression(id: 1, name: 'Normal', config: FaceConfig());
  }

  String get brainUrl => 'ws://$brainHost:$brainPort';

  AppSettings copy() => AppSettings(
        brainHost: brainHost,
        brainPort: brainPort,
        cameraFront: cameraFront,
        imuRateHz: imuRateHz,
        gpsEnabled: gpsEnabled,
        imuEnabled: imuEnabled,
        cameraEnabled: cameraEnabled,
        voiceEnabled: voiceEnabled,
        wakeWord: wakeWord,
        ttsLanguage: ttsLanguage,
        sttLocaleId: sttLocaleId,
        ttsEnabled: ttsEnabled,
        speechBubbleEnabled: speechBubbleEnabled,
        ignoreRepeatedSpeech: ignoreRepeatedSpeech,
        faceAutoHide: faceAutoHide,
        faceAutoHideSeconds: faceAutoHideSeconds,
        activeExpressionId: activeExpressionId,
        expressions: [for (final e in expressions) e.copy()],
      );

  static const _kPrefix = 'smabo.';

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    String s(String k, String d) => p.getString('$_kPrefix$k') ?? d;
    int i(String k, int d) => p.getInt('$_kPrefix$k') ?? d;
    bool b(String k, bool d) => p.getBool('$_kPrefix$k') ?? d;
    return AppSettings(
      brainHost: s('brainHost', '192.168.4.2'),
      brainPort: i('brainPort', 9090),
      cameraFront: b('cameraFront', true),
      imuRateHz: i('imuRateHz', 20),
      gpsEnabled: b('gpsEnabled', false),
      imuEnabled: b('imuEnabled', false),
      cameraEnabled: b('cameraEnabled', false),
      voiceEnabled: b('voiceEnabled', true),
      wakeWord: s('wakeWord', 'smabo'),
      ttsLanguage: s('ttsLanguage', 'ja-JP'),
      sttLocaleId: s('sttLocaleId', 'ja_JP'),
      ttsEnabled: b('ttsEnabled', true),
      speechBubbleEnabled: b('speechBubbleEnabled', true),
      ignoreRepeatedSpeech: b('ignoreRepeatedSpeech', true),
      faceAutoHide: b('faceAutoHide', true),
      faceAutoHideSeconds: i('faceAutoHideSeconds', 5),
      activeExpressionId: i('activeExpressionId', 1),
      expressions: _loadExpressions(p),
    );
  }

  static List<FaceExpression> _loadExpressions(SharedPreferences p) {
    final raw = p.getString('${_kPrefix}faceExpressions');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) =>
                FaceExpression.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        if (list.isNotEmpty) return list;
      } catch (_) {}
    }
    final templates = FaceExpression.templates();
    final legacy = p.getString('${_kPrefix}faceConfig');
    if (legacy != null && legacy.isNotEmpty) {
      templates.first.config = FaceConfig.decode(legacy);
    }
    return templates;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('${_kPrefix}brainHost', brainHost);
    await p.setInt('${_kPrefix}brainPort', brainPort);
    await p.setBool('${_kPrefix}cameraFront', cameraFront);
    await p.setInt('${_kPrefix}imuRateHz', imuRateHz);
    await p.setBool('${_kPrefix}gpsEnabled', gpsEnabled);
    await p.setBool('${_kPrefix}imuEnabled', imuEnabled);
    await p.setBool('${_kPrefix}cameraEnabled', cameraEnabled);
    await p.setBool('${_kPrefix}voiceEnabled', voiceEnabled);
    await p.setString('${_kPrefix}wakeWord', wakeWord);
    await p.setString('${_kPrefix}ttsLanguage', ttsLanguage);
    await p.setString('${_kPrefix}sttLocaleId', sttLocaleId);
    await p.setBool('${_kPrefix}ttsEnabled', ttsEnabled);
    await p.setBool('${_kPrefix}speechBubbleEnabled', speechBubbleEnabled);
    await p.setBool('${_kPrefix}ignoreRepeatedSpeech', ignoreRepeatedSpeech);
    await p.setBool('${_kPrefix}faceAutoHide', faceAutoHide);
    await p.setInt('${_kPrefix}faceAutoHideSeconds', faceAutoHideSeconds);
    await p.setInt('${_kPrefix}activeExpressionId', activeExpressionId);
    await p.setString('${_kPrefix}faceExpressions',
        jsonEncode([for (final e in expressions) e.toJson()]));
  }
}
