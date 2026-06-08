import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_recognition_error.dart';

/// Phase of the voice pipeline.
///
/// [idle] — not listening. [listeningForWake] — continuously listening for the
/// wake word. [recognizing] — wake word heard, capturing the actual command.
enum VoiceState { idle, listeningForWake, recognizing }

/// On-device speech recognition with a best-effort wake word.
///
/// Uses the platform's on-device STT ([speech_to_text]) in a continuous loop.
/// While in [VoiceState.listeningForWake] it scans transcripts for the wake
/// word; once heard it switches to [VoiceState.recognizing] and emits the
/// spoken command via [onCommand].
///
/// Wake-word matching is fuzzy because a Japanese recogniser transcribes
/// "smabo" as katakana (e.g. スマホ / スマボ), not the latin word — so we match
/// against a set of variants. A spoken trigger is best-effort; [triggerRecognition]
/// provides a guaranteed manual fallback (e.g. tapping the face).
class SpeechService {
  final SpeechToText _stt = SpeechToText();

  bool _available = false;
  bool _enabled = false;
  String _wakeWord = 'smabo';
  String _localeId = 'ja_JP';
  List<String> _wakeVariants = const ['smabo'];

  VoiceState _state = VoiceState.idle;
  VoiceState get state => _state;
  bool get isAvailable => _available;

  final _stateController = StreamController<VoiceState>.broadcast();
  final _commandController = StreamController<String>.broadcast();
  final _partialController = StreamController<String>.broadcast();
  final _debugController = StreamController<String>.broadcast();
  final _wakeController = StreamController<void>.broadcast();

  Stream<VoiceState> get stateStream => _stateController.stream;

  /// Fires once each time the wake word is detected (or recognition is started
  /// manually). A one-shot pulse, independent of how long recognition lasts.
  Stream<void> get onWake => _wakeController.stream;

  /// Emits the recognized command string once a wake-word session completes.
  Stream<String> get onCommand => _commandController.stream;

  /// Emits live transcripts (both phases) for on-screen feedback.
  Stream<String> get onPartial => _partialController.stream;

  /// Emits human-readable diagnostics (availability, status, errors, heard
  /// text) — surfaced in the app's log so wake issues are debuggable.
  Stream<String> get debug => _debugController.stream;

  Future<bool> init({required String wakeWord, required String localeId}) async {
    _wakeWord = wakeWord.toLowerCase();
    _localeId = localeId;
    _computeVariants();

    // STT needs the microphone permission; request it explicitly so a denial
    // is visible rather than silently disabling recognition.
    final mic = await Permission.microphone.request();
    _log('Mic permission: ${mic.name}');
    if (!mic.isGranted) {
      _log('⚠️ Microphone permission not granted; speech recognition disabled');
      _available = false;
      return false;
    }

    _available = await _stt.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    _log('Speech recognition available: $_available  (wake="$_wakeWord", locale=$_localeId)');
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
  }

  /// Start the always-on listening loop.
  Future<void> start() async {
    if (!_available || _enabled) return;
    _enabled = true;
    await _listen();
  }

  /// Stop all listening.
  Future<void> stop() async {
    _enabled = false;
    await _stt.stop();
    _setState(VoiceState.idle);
  }

  // One continuous session waits for the wake word and then keeps capturing
  // the command in the SAME session — no stop/restart gap, so the wake word
  // cannot bleed into a second session and listening feels Siri-like.
  bool _armed = false; // wake heard → now capturing a command
  String _lastText = ''; // latest transcript (used to finalise on session end)

  Future<void> _listen() async {
    if (!_enabled) return;
    _lastText = '';
    _setState(_armed ? VoiceState.recognizing : VoiceState.listeningForWake);
    try {
      await _stt.listen(
        onResult: _onResult,
        localeId: _localeId,
        // Siri-like: a long overall window and several seconds of tolerated
        // silence before the phrase is finalised, so it keeps listening while
        // (and a bit after) you talk.
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
      );
    } catch (e) {
      _log('listen failed: $e');
      _restart();
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords;
    _lastText = text;

    if (!_armed) {
      if (text.isNotEmpty) {
        _partialController.add(text);
        _log('🔎 Heard: "$text"');
      }
      if (_matchesWake(text)) {
        _armed = true;
        _log('✅ Wake word detected');
        if (!_wakeController.isClosed) _wakeController.add(null);
        _setState(VoiceState.recognizing);
      }
    }

    if (_armed) {
      _partialController.add(_commandPart(text)); // command without wake word
    }

    if (result.finalResult) {
      _finalize();
      _restart();
    }
  }

  /// Resolve the captured command and return to wake-listening. Idempotent, so
  /// it is safe to call from both [_onResult] (finalResult) and [_onStatus]
  /// (session end) — important because some platforms end a session via the
  /// status callback WITHOUT ever delivering a final result, which otherwise
  /// left the service stuck in the "listening" state.
  void _finalize() {
    if (!_armed) return;
    final cmd = _commandPart(_lastText);
    if (cmd.isNotEmpty) {
      _log('🎤 Command: "$cmd"');
      _commandController.add(cmd);
    } else {
      _log('(no command)');
    }
    _disarm();
  }

  /// The command portion of the transcript: everything AFTER the wake word.
  ///
  /// Located by searching the actual (possibly revised) transcript for a wake
  /// variant and taking the text after its end — so the start of the command is
  /// preserved (a fixed cut-point truncated it). Falls back to a variant strip,
  /// then to the whole text when no wake word is present (manual trigger).
  String _commandPart(String text) {
    final lower = text.toLowerCase();
    var afterEnd = -1;
    for (final v in _wakeVariants) {
      if (v.isEmpty) continue;
      final idx = lower.indexOf(v.toLowerCase());
      if (idx >= 0) {
        final end = idx + v.length;
        if (end > afterEnd) afterEnd = end; // take after the latest-ending match
      }
    }
    final cmd = (afterEnd >= 0 && afterEnd <= text.length)
        ? text.substring(afterEnd)
        : text;
    return _stripWakeWord(cmd);
  }

  void _disarm() {
    _armed = false;
  }

  String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  bool _matchesWake(String text) {
    final n = _normalize(text);
    if (n.isEmpty) return false;
    return _wakeVariants.any((v) => n.contains(_normalize(v)));
  }

  /// Skip the wake word and start capturing a command immediately (manual
  /// fallback, e.g. tapping the face).
  Future<void> triggerRecognition() async {
    if (!_available) {
      _log('⚠️ Speech recognition unavailable; cannot start manually');
      return;
    }
    _enabled = true;
    _armed = true;
    _log('🎤 Manual voice capture started');
    if (!_wakeController.isClosed) _wakeController.add(null);
    await _stt.stop();
    await _listen();
  }

  String _stripWakeWord(String text) {
    // The wake word is only a trigger — remove every occurrence of any of its
    // variants so it never leaks into the command that gets sent.
    var out = text;
    for (final v in _wakeVariants) {
      if (v.isEmpty) continue;
      out = out.replaceAll(
        RegExp(RegExp.escape(v), caseSensitive: false),
        '',
      );
    }
    // Trim leftover edge whitespace/punctuation.
    return out.replaceAll(RegExp(r'^[\s、。,.\-]+'), '').trim();
  }

  void _onStatus(String status) {
    _log('status: $status');
    if (!_enabled) return;
    // The platform stops the session after silence. Some platforms end here
    // WITHOUT a final result, so finalise any captured command, then reopen.
    if (status == 'done' || status == 'notListening') {
      _finalize();
      _restart();
    }
  }

  void _onError(SpeechRecognitionError error) {
    _log('error: ${error.errorMsg} (permanent=${error.permanent})');
    if (!_enabled) return;
    _finalize();
    _restart();
  }

  // Reopen the single listening session (debounced so overlapping triggers —
  // a final result plus a "done" status — coalesce into one restart).
  Timer? _restartTimer;
  void _restart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 500), () {
      if (_enabled) _listen();
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
    _stt.stop();
    _stateController.close();
    _commandController.close();
    _partialController.close();
    _debugController.close();
    _wakeController.close();
  }
}
