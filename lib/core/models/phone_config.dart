import 'app_settings.dart';
import 'face_expression.dart';

/// The phone's settings as a JSON tree: what the REST `/config` serves
/// (port [phoneConfigPort]) and what `/app/phone/config` publishes.
///
/// Same idea as the ESP32's REST config API: `GET /config` returns the whole
/// tree, `POST /config` deep-merges a partial one. smabo-sim serves the same
/// contract (smabo_sim/phone/settings.py), so smabo-web edits a simulated and a
/// real phone the same way.
///
/// ```
/// {
///   "brain":   {"host": str, "port": int},                 read-only
///   "http":    {"port": int},                              read-only
///   "sensors": {"imu":    {"enabled": bool, "rate_hz": int},
///               "gps":    {"enabled": bool},
///               "camera": {"enabled": bool, "front": bool}},
///   "voice":   {"enabled": bool, "wake_word": str, "stt_locale": str},
///   "speech":  {"tts": bool, "tts_language": str, "bubble": bool, "ignore_repeated": bool},
///   "face":    {"auto_hide": bool, "auto_hide_seconds": int,
///               "expression": str,          the name shown (matched ignoring case)
///               "expressions": [str]},      the names, read-only
///   "app":     {"name": str, "version": str, "schema": int}  read-only
/// }
/// ```
/// Unknown and read-only keys in a patch are ignored and listed back.
const phoneConfigSchema = 1;
const phoneConfigPort = 8081;

/// pubspec.yaml's version (test/phone_config_test.dart checks they match).
const appVersion = '0.2.0+5';

Map<String, dynamic> phoneConfigToJson(AppSettings s, {int httpPort = phoneConfigPort}) => {
      'brain': {'host': s.brainHost, 'port': s.brainPort},
      'http': {'port': httpPort},
      'sensors': {
        'imu': {'enabled': s.imuEnabled, 'rate_hz': s.imuRateHz},
        'gps': {'enabled': s.gpsEnabled},
        'camera': {'enabled': s.cameraEnabled, 'front': s.cameraFront},
      },
      'voice': {
        'enabled': s.voiceEnabled,
        'wake_word': s.wakeWord,
        'stt_locale': s.sttLocaleId,
      },
      'speech': {
        'tts': s.ttsEnabled,
        'tts_language': s.ttsLanguage,
        'bubble': s.speechBubbleEnabled,
        'ignore_repeated': s.ignoreRepeatedSpeech,
      },
      'face': {
        'auto_hide': s.faceAutoHide,
        'auto_hide_seconds': s.faceAutoHideSeconds,
        'expression': s.expressionById(s.activeExpressionId).name,
        'expressions': [for (final e in s.expressions) e.name],
      },
      'app': {'name': 'smabo-app', 'version': appVersion, 'schema': phoneConfigSchema},
    };

/// The writable paths and their JSON types.
const phoneConfigWritable = <String, Type>{
  'sensors.imu.enabled': bool,
  'sensors.imu.rate_hz': int,
  'sensors.gps.enabled': bool,
  'sensors.camera.enabled': bool,
  'sensors.camera.front': bool,
  'voice.enabled': bool,
  'voice.wake_word': String,
  'voice.stt_locale': String,
  'speech.tts': bool,
  'speech.tts_language': String,
  'speech.bubble': bool,
  'speech.ignore_repeated': bool,
  'face.auto_hide': bool,
  'face.auto_hide_seconds': int,
  'face.expression': String,
};

const _limits = <String, (int, int)>{
  'sensors.imu.rate_hz': (1, 200),
  'face.auto_hide_seconds': (1, 3600),
};

/// A checked patch: the values to apply (by path) and the paths ignored.
class PhoneConfigPatch {
  PhoneConfigPatch(this.values, this.ignored);
  final Map<String, Object> values;
  final List<String> ignored;
}

/// Flatten [patch] and keep what is writable and well-typed (no silent
/// string → bool etc.). [expressionNames] are the expressions that exist.
PhoneConfigPatch parsePhoneConfigPatch(Map<String, dynamic> patch,
    {Iterable<String> expressionNames = const []}) {
  final names = {for (final n in expressionNames) expressionKey(n)};
  final values = <String, Object>{};
  final ignored = <String>[];
  void walk(Map<String, dynamic> node, String prefix) {
    node.forEach((k, v) {
      final path = '$prefix$k';
      if (v is Map) {
        walk(v.cast<String, dynamic>(), '$path.');
        return;
      }
      final type = phoneConfigWritable[path];
      Object? value;
      if (type == bool && v is bool) {
        value = v;
      } else if (type == int && v is num && v == v.roundToDouble()) {
        var i = v.toInt();
        final lim = _limits[path];
        if (lim != null) i = i.clamp(lim.$1, lim.$2);
        value = i;
      } else if (type == String && v is String && v.trim().isNotEmpty) {
        value = v.trim();
      }
      if (path == 'face.expression' && (value is! String || !names.contains(expressionKey(value)))) {
        value = null;
      }
      if (value == null) {
        ignored.add(path);
      } else {
        values[path] = value;
      }
    });
  }

  walk(patch, '');
  return PhoneConfigPatch(values, ignored);
}
