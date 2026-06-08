import 'package:flutter_tts/flutter_tts.dart';

/// Text-to-speech wrapper used to read aloud `std_msgs/String` messages
/// received on `/speech/say`.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  Future<void> init(String language) async {
    await _tts.setLanguage(language);
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _ready = true;
  }

  Future<void> setLanguage(String language) async {
    await _tts.setLanguage(language);
  }

  /// Speak [text]. Interrupts any current utterance.
  Future<void> speak(String text) async {
    if (!_ready || text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}
