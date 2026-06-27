import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_recognition_error.dart';

/// Phase of the voice pipeline.
///
/// [idle] — not listening. [listeningForWake] — continuously listening for the
/// wake word. [recognizing] — wake word heard, now *recording* the utterance
/// (the STT itself runs on smabo-brain, not here).
enum VoiceState { idle, listeningForWake, recognizing }

/// Wake-word detection on the phone, with the actual speech-to-text done on
/// smabo-brain.
///
/// The phone uses the platform's on-device recogniser ([speech_to_text]) only
/// to spot the wake word. Once heard it stops that recogniser, **records the
/// spoken utterance** ([record], 16 kHz mono PCM) until a short silence, wraps
/// it as a WAV and emits it (base64) on [onAudio]; smabo-brain transcribes it
/// and publishes `/speech/recognized`.
///
/// Wake-word matching is fuzzy because a Japanese recogniser transcribes
/// "smabo" as katakana (e.g. スマホ / スマボ), not the latin word — so we match
/// against a set of variants. A spoken trigger is best-effort; [triggerRecognition]
/// provides a guaranteed manual fallback (e.g. tapping the face).
class SpeechService {
  final SpeechToText _stt = SpeechToText();
  // Recreated per utterance and fully disposed afterwards: that releases the
  // native mic so the wake recogniser (speech_to_text) can reacquire it for the
  // next wake. Just stopping it left the mic held → 2nd wake never fired.
  AudioRecorder? _recorder;

  bool _available = false;
  bool _enabled = false;
  String _wakeWord = 'smabo';
  String _localeId = 'ja_JP';
  List<String> _wakeVariants = const ['smabo'];

  // --- recording / silence detection ---
  static const int _sampleRate = 16000;     // STT-friendly mono rate
  static const int _silenceMs = 1500;       // stop after this much continuous silence
  static const double _silenceRms = 600.0;  // int16 RMS at/under this = silence
  final BytesBuilder _pcm = BytesBuilder();
  StreamSubscription<Uint8List>? _recSub;
  Timer? _silenceTimer;
  int _lastVoiceAtMs = 0;
  bool _heardVoice = false;

  VoiceState _state = VoiceState.idle;
  VoiceState get state => _state;
  bool get isAvailable => _available;

  final _stateController = StreamController<VoiceState>.broadcast();
  final _audioController = StreamController<String>.broadcast();
  final _partialController = StreamController<String>.broadcast();
  final _debugController = StreamController<String>.broadcast();
  final _wakeController = StreamController<void>.broadcast();

  Stream<VoiceState> get stateStream => _stateController.stream;

  /// Fires once each time the wake word is detected (or recording is started
  /// manually). A one-shot pulse, independent of how long recording lasts.
  Stream<void> get onWake => _wakeController.stream;

  /// Emits a base64-encoded 16 kHz mono WAV once an utterance has been recorded
  /// (wake word heard → recorded until silence). smabo-brain runs the STT.
  Stream<String> get onAudio => _audioController.stream;

  /// Emits live wake-word transcripts / recording hints for on-screen feedback.
  Stream<String> get onPartial => _partialController.stream;

  /// Emits human-readable diagnostics (availability, status, errors, heard
  /// text) — surfaced in the app's log so wake issues are debuggable.
  Stream<String> get debug => _debugController.stream;

  Future<bool> init({required String wakeWord, required String localeId}) async {
    _wakeWord = wakeWord.toLowerCase();
    _localeId = localeId;
    _computeVariants();

    // Both wake STT and recording need the microphone permission; request it
    // explicitly so a denial is visible rather than silently disabling voice.
    final mic = await Permission.microphone.request();
    _log('Mic permission: ${mic.name}');
    if (!mic.isGranted) {
      _log('⚠️ Microphone permission not granted; voice disabled');
      _available = false;
      return false;
    }

    _available = await _stt.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    _log('Wake recogniser available: $_available  (wake="$_wakeWord", locale=$_localeId)');
    if (!_available) {
      _log('⚠️ Could not initialise speech recognition (device may not support it)');
    }
    return _available;
  }

  void _computeVariants() {
    final w = _wakeWord.trim().toLowerCase();
    final set = <String>{if (w.isNotEmpty) w};
    // A ja-JP recogniser renders "smabo" as katakana; accept common spellings.
    if (w == 'smabo' || w == 'sumabo' || w == 'スマボ') {
      set.addAll(['smabo', 'sumabo', 'スマボ', 'すまぼ', 'スマホ', 'すまほ']);
    }
    _wakeVariants = set.toList();
  }

  void updateConfig({String? wakeWord, String? localeId}) {
    if (wakeWord != null) _wakeWord = wakeWord.toLowerCase();
    if (localeId != null) _localeId = localeId;
    _computeVariants();
    _log('Wake config updated: wake="$_wakeWord" variants=$_wakeVariants '
        'locale=$_localeId');
    // If we're currently waiting for the wake word, restart the recogniser so
    // the new wake word / locale takes effect immediately on a fresh session
    // (the old session keeps the locale it was started with).
    if (_enabled && _state == VoiceState.listeningForWake) {
      _stt.stop();
      _restartWake();
    }
  }

  /// Start the always-on wake-word listening loop.
  Future<void> start() async {
    if (!_available || _enabled) return;
    _enabled = true;
    await _listenForWake();
  }

  /// Stop all listening / recording.
  Future<void> stop() async {
    _enabled = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _recSub?.cancel();
    _recSub = null;
    await _disposeRecorder();
    await _stt.stop();
    _setState(VoiceState.idle);
  }

  /// Stop and fully tear down the recorder, releasing the native mic.
  Future<void> _disposeRecorder() async {
    final rec = _recorder;
    _recorder = null;
    if (rec == null) return;
    try {
      if (await rec.isRecording()) await rec.stop();
    } catch (_) {}
    try {
      await rec.dispose();
    } catch (_) {}
  }

  // -------------------------------------------------------------- wake word
  Future<void> _listenForWake() async {
    if (!_enabled) return;
    _setState(VoiceState.listeningForWake);
    try {
      await _stt.listen(
        onResult: _onWakeResult,
        localeId: _localeId,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
      );
    } catch (e) {
      _log('wake listen failed: $e');
      _restartWake();
    }
  }

  void _onWakeResult(SpeechRecognitionResult result) {
    // Ignore stale/late callbacks: once we leave wake-listening (e.g. recording
    // started), a final result delivered by the just-stopped recogniser must NOT
    // restart wake listening, or it would tear down the in-progress recording.
    if (_state != VoiceState.listeningForWake) return;
    _consecutiveErrors = 0; // recogniser is delivering results → healthy
    final text = result.recognizedWords;
    if (text.isNotEmpty) {
      _partialController.add(text);
      _log('🔎 Heard: "$text"');
    }
    if (_matchesWake(text)) {
      _onWakeDetected();
    } else if (result.finalResult) {
      _restartWake();
    }
  }

  Future<void> _onWakeDetected() async {
    if (_state == VoiceState.recognizing) return; // already recording
    _log('✅ Wake word detected → recording');
    if (!_wakeController.isClosed) _wakeController.add(null);
    await _stt.stop();
    await _startRecording();
  }

  /// Skip the wake word and start recording immediately (manual fallback,
  /// e.g. tapping the face).
  Future<void> triggerRecognition() async {
    if (!_available) {
      _log('⚠️ Voice unavailable; cannot start manually');
      return;
    }
    _enabled = true;
    if (_state == VoiceState.recognizing) return;
    _log('🎤 Manual recording started');
    if (!_wakeController.isClosed) _wakeController.add(null);
    await _stt.stop();
    await _startRecording();
  }

  // --------------------------------------------------------------- recording
  Future<void> _startRecording() async {
    // Enter the recording state up-front (and cancel any pending wake re-listen)
    // BEFORE any await, so late callbacks from the just-stopped wake recogniser
    // are ignored (see _onWakeResult) even during the hasPermission() gap.
    _restartTimer?.cancel();
    _setState(VoiceState.recognizing);
    _pcm.clear();
    _heardVoice = false;
    _lastVoiceAtMs = DateTime.now().millisecondsSinceEpoch;

    // Fresh recorder each time (disposed in _finishRecording) for a clean mic
    // hand-off back to the wake recogniser.
    final rec = AudioRecorder();
    _recorder = rec;
    if (!await rec.hasPermission()) {
      _log('⚠️ No mic permission for recording');
      await _disposeRecorder();
      _restartWake();
      return;
    }
    try {
      final stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ));
      _recSub = stream.listen(
        _onPcmChunk,
        onError: (e) {
          _log('recording error: $e');
          _finishRecording(send: false);
        },
      );
      // Backstop in case PCM chunks stop arriving without an error.
      _silenceTimer = Timer.periodic(
          const Duration(milliseconds: 200), (_) => _checkSilence());
    } catch (e) {
      _log('startStream failed: $e');
      await _disposeRecorder();
      _restartWake();
    }
  }

  void _onPcmChunk(Uint8List chunk) {
    _pcm.add(chunk);
    if (_rms16(chunk) > _silenceRms) {
      _heardVoice = true;
      _lastVoiceAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    _partialController.add(_heardVoice ? '🎙 録音中…' : 'お話しください');
    _checkSilence();
  }

  void _checkSilence() {
    if (_state != VoiceState.recognizing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastVoiceAtMs >= _silenceMs) {
      // Only send when we actually captured speech; pure silence is discarded.
      _finishRecording(send: _heardVoice);
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    if (_state != VoiceState.recognizing) return; // guard against re-entry
    _setState(VoiceState.idle);
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _recSub?.cancel();
    _recSub = null;
    await _disposeRecorder(); // fully release the mic

    final pcm = _pcm.toBytes();
    _pcm.clear();
    if (send && pcm.isNotEmpty) {
      final wav = _buildWav(pcm, _sampleRate, 1, 16);
      _log('🎤 Utterance captured (${pcm.length} B PCM) → brain');
      if (!_audioController.isClosed) _audioController.add(base64Encode(wav));
    } else {
      _log('(no speech captured)');
    }
    // Let the OS finish releasing the mic before the wake recogniser reacquires
    // it, otherwise the next wake session silently fails to start.
    await Future.delayed(const Duration(milliseconds: 350));
    _restartWake();
  }

  /// RMS amplitude of a little-endian 16-bit PCM chunk (0..32767-ish).
  double _rms16(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    if (n == 0) return 0;
    final data = ByteData.sublistView(bytes);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = data.getInt16(i * 2, Endian.little).toDouble();
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }

  /// Prepend a 44-byte WAV (PCM) header to raw little-endian PCM samples.
  Uint8List _buildWav(Uint8List pcm, int sampleRate, int channels, int bits) {
    final byteRate = sampleRate * channels * bits ~/ 8;
    final blockAlign = channels * bits ~/ 8;
    final b = BytesBuilder();
    void s(String v) => b.add(ascii.encode(v));
    void u32(int v) =>
        b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    s('RIFF');
    u32(36 + pcm.length);
    s('WAVE');
    s('fmt ');
    u32(16); // PCM fmt chunk size
    u16(1); // audio format = PCM
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bits);
    s('data');
    u32(pcm.length);
    b.add(pcm);
    return b.toBytes();
  }

  // ------------------------------------------------------------- wake helpers
  String _normalize(String v) =>
      v.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  bool _matchesWake(String text) {
    final n = _normalize(text);
    if (n.isEmpty) return false;
    return _wakeVariants.any((v) => n.contains(_normalize(v)));
  }

  void _onStatus(String status) {
    if (!_enabled) return;
    // While waiting for the wake word, the platform ends a session after
    // silence; reopen it. (During recording the wake recogniser is stopped.)
    // Routine statuses are not logged — they fire constantly in always-on mode.
    if (_state == VoiceState.listeningForWake &&
        (status == 'done' || status == 'notListening')) {
      _restartWake();
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (!_enabled) return;
    if (_state != VoiceState.listeningForWake) return;
    // error_speech_timeout / error_no_match are the NORMAL outcome of always-on
    // wake listening (no speech in the window) — just reopen calmly. Other
    // errors (notably error_client = recogniser busy) get a growing backoff so
    // we don't spin it into a broken state with a tight listen→error loop.
    final msg = error.errorMsg;
    final benign = msg.contains('speech_timeout') || msg.contains('no_match');
    if (benign) {
      _consecutiveErrors = 0;
      _restartWake();
    } else {
      _consecutiveErrors++;
      _log('stt error: $msg (permanent=${error.permanent}) '
          '#$_consecutiveErrors');
      final backoff = (400 * _consecutiveErrors).clamp(600, 5000);
      _restartWake(delayMs: backoff);
    }
  }

  // Reopen the wake session (debounced so overlapping triggers coalesce). A
  // generous default gap lets the Android recogniser fully tear down its
  // previous session, which avoids error_client on the next listen.
  Timer? _restartTimer;
  int _consecutiveErrors = 0;
  void _restartWake({int delayMs = 700}) {
    _restartTimer?.cancel();
    _restartTimer = Timer(Duration(milliseconds: delayMs), () {
      // Don't reopen wake listening if a recording is in progress.
      if (_enabled && _state != VoiceState.recognizing) _listenForWake();
    });
  }

  void _setState(VoiceState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _log(String msg) {
    if (!_debugController.isClosed) _debugController.add(msg);
  }

  void dispose() {
    _restartTimer?.cancel();
    _silenceTimer?.cancel();
    _recSub?.cancel();
    _recorder?.dispose();
    _stt.stop();
    _stateController.close();
    _audioController.close();
    _partialController.close();
    _debugController.close();
    _wakeController.close();
  }
}
