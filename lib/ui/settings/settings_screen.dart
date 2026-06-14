import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/app_settings.dart';
import '../../state/app_state.dart';
import 'sensor_preview.dart';

/// Settings: brain connection endpoint, sensor/voice options and face UI.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _draft;
  late final TextEditingController _brainHost;
  late final TextEditingController _brainPort;
  late final TextEditingController _wakeWord;

  static const _ttsLanguages = [
    'en-US', 'en-GB', 'ja-JP', 'ko-KR', 'zh-CN', 'fr-FR', 'de-DE', 'es-ES',
  ];
  static const _sttLocales = [
    'en_US', 'en_GB', 'ja_JP', 'ko_KR', 'zh_CN', 'fr_FR', 'de_DE', 'es_ES',
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _draft = context.read<AppState>().settings.copy();
    _brainHost = TextEditingController(text: _draft.brainHost);
    _brainPort = TextEditingController(text: '${_draft.brainPort}');
    _wakeWord = TextEditingController(text: _draft.wakeWord);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _brainHost.dispose();
    _brainPort.dispose();
    _wakeWord.dispose();
    super.dispose();
  }

  Future<void> _saveAppSettings() async {
    _draft
      ..brainHost = _brainHost.text.trim()
      ..brainPort = int.tryParse(_brainPort.text) ?? 9090
      ..wakeWord = _wakeWord.text.trim();
    await context.read<AppState>().updateSettings(_draft);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  void _applyFaceSettings() {
    final s = context.read<AppState>().settings.copy()
      ..faceAutoHide = _draft.faceAutoHide
      ..faceAutoHideSeconds = _draft.faceAutoHideSeconds;
    context.read<AppState>().updateSettings(s);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _toc(),
          _section('Connections'),
          _hostPort('brain (eye control, mic, imu, camera, gps)',
              _brainHost, _brainPort),
          ElevatedButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Save & reconnect'),
            onPressed: _saveAppSettings,
          ),

          const SizedBox(height: 24),
          _section('Camera'),
          _lensSelector(state),
          _cameraFormat(),
          _intField('FPS', _draft.cameraFps, (v) => _draft.cameraFps = v),
          _intField('JPEG quality (1-100)', _draft.cameraJpegQuality,
              (v) => _draft.cameraJpegQuality = v),

          const SizedBox(height: 24),
          _section('IMU'),
          _intField('Publish rate (Hz)', _draft.imuRateHz,
              (v) => _draft.imuRateHz = v),

          const SizedBox(height: 24),
          _section('Sensor preview'),
          SensorPreview(state: state),

          const SizedBox(height: 24),
          _section('Voice'),
          _textField('Wake word', _wakeWord),
          _langDropdown(
            'Speech (TTS) language',
            _ttsLanguages,
            _draft.ttsLanguage,
            (v) => setState(() => _draft.ttsLanguage = v),
          ),
          _langDropdown(
            'Recognition locale',
            _sttLocales,
            _draft.sttLocaleId,
            (v) => setState(() => _draft.sttLocaleId = v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Read aloud received text (TTS)'),
            subtitle: const Text(
                'Speak text received on /speech/say. Also toggleable from the '
                'face screen.'),
            value: _draft.ttsEnabled,
            onChanged: (v) {
              setState(() => _draft.ttsEnabled = v);
              context.read<AppState>().toggleTts(v);
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Show received text as a speech bubble'),
            subtitle: const Text(
                'Display text received on /speech/say over the face. Also '
                'toggleable from the face screen.'),
            value: _draft.speechBubbleEnabled,
            onChanged: (v) {
              setState(() => _draft.speechBubbleEnabled = v);
              context.read<AppState>().toggleSpeechBubble(v);
            },
          ),

          const SizedBox(height: 24),
          _section('Overlay UI'),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-hide overlay UI'),
            subtitle: const Text(
                'Hide the status / sensor / settings buttons after a delay. '
                'Tap the screen to show them again.'),
            value: _draft.faceAutoHide,
            onChanged: (v) {
              setState(() => _draft.faceAutoHide = v);
              _applyFaceSettings();
            },
          ),
          if (_draft.faceAutoHide)
            _intField('Hide after (seconds)', _draft.faceAutoHideSeconds, (v) {
              _draft.faceAutoHideSeconds = v;
              _applyFaceSettings();
            }),

          const SizedBox(height: 24),
          _section('Log'),
          _logView(state),
          ],
        ),
      ),
    );
  }

  // ---- table of contents ----
  static const _sectionTitles = [
    'Connections',
    'Camera',
    'IMU',
    'Sensor preview',
    'Voice',
    'Overlay UI',
    'Log',
  ];
  final Map<String, GlobalKey> _sectionKeys = {
    for (final t in _sectionTitles) t: GlobalKey(),
  };

  void _jumpTo(String title) {
    final ctx = _sectionKeys[title]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    }
  }

  Widget _toc() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Contents',
              style: TextStyle(
                  color: Colors.white54, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              for (final t in _sectionTitles)
                InkWell(
                  onTap: () => _jumpTo(t),
                  child: Text(t,
                      style: const TextStyle(
                          color: Colors.cyanAccent,
                          decoration: TextDecoration.underline)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        key: _sectionKeys[t],
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      );

  Widget _hostPort(
      String label, TextEditingController host, TextEditingController port) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54)),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: host,
                  decoration: const InputDecoration(hintText: 'Host / IP'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'Port'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _langDropdown(
    String label,
    List<String> options,
    String current,
    ValueChanged<String> onChanged,
  ) {
    final items = [
      ...options,
      if (!options.contains(current)) current,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          DropdownButton<String>(
            value: current,
            dropdownColor: const Color(0xFF111111),
            items: [
              for (final o in items)
                DropdownMenuItem(value: o, child: Text(o)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _lensSelector(AppState state) {
    final front = _draft.cameraFront;
    void set(bool f) {
      setState(() => _draft.cameraFront = f);
      state.setCameraFront(f);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Text('Lens: ', style: TextStyle(color: Colors.white54)),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Front'),
            selected: front,
            onSelected: (_) => set(true),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Back'),
            selected: !front,
            onSelected: (_) => set(false),
          ),
        ],
      ),
    );
  }

  Widget _intField(String label, int value, void Function(int) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: TextEditingController(text: '$value'),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (s) {
          final v = int.tryParse(s);
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _cameraFormat() {
    return Row(
      children: [
        const Text('Format: ', style: TextStyle(color: Colors.white54)),
        const SizedBox(width: 8),
        DropdownButton<CameraFormat>(
          value: _draft.cameraFormat,
          dropdownColor: const Color(0xFF111111),
          items: const [
            DropdownMenuItem(
                value: CameraFormat.compressed,
                child: Text('CompressedImage (JPEG)')),
            DropdownMenuItem(
                value: CameraFormat.raw, child: Text('Image (raw mono8)')),
          ],
          onChanged: (v) =>
              setState(() => _draft.cameraFormat = v ?? CameraFormat.compressed),
        ),
      ],
    );
  }

  Widget _logView(AppState state) {
    return Container(
      height: 160,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        children: state.log
            .map((l) => Text(l,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white70)))
            .toList(),
      ),
    );
  }
}
