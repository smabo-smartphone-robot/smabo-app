import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../../core/models/face_config.dart';
import '../../state/app_state.dart';
import 'eye_painter.dart';

part 'face_preview.dart';
part 'size_field.dart';

/// Dedicated, landscape face-customisation screen: a live preview on the left
/// and the controls on the right. The top of the controls manages the list of
/// expressions (each shown with its ID); below that, each eye is configured
/// independently — the "separate eyes" toggle is first, and the visible controls
/// depend on each eye's shape.
class FaceSettingsScreen extends StatefulWidget {
  const FaceSettingsScreen({super.key});

  @override
  State<FaceSettingsScreen> createState() => _FaceSettingsScreenState();
}

class _FaceSettingsScreenState extends State<FaceSettingsScreen> {
  late FaceConfig _d;
  late final AppState _state;
  late int _editingId;

  String? _openColor; // which colour row's inline picker is expanded (by key)
  int _colorMode = 0; // 0 = wheel, 1 = RGB, 2 = HSV

  @override
  void initState() {
    super.initState();
    // Keep this screen landscape (the main settings screen is portrait).
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _state = context.read<AppState>();
    _editingId = _state.activeExpressionId;
    _state.beginEditExpression(_editingId);
    _d = _state.expressionById(_editingId).config.copy();
  }

  @override
  void dispose() {
    // Persist the final state in case the last edit was an in-progress drag.
    _state.commitEditExpression(_d);
    _state.endEditExpression();
    super.dispose();
  }

  void _preview() => _state.previewFaceConfig(_d);
  void _commit() => _state.commitEditExpression(_d);

  /// Switch which expression is being edited (committing the current one).
  /// Selecting an expression also makes it the active (shown) one.
  void _editExpression(int id) {
    _commit();
    setState(() {
      _editingId = id;
      _d = _state.expressionById(id).config.copy();
      _openColor = null;
    });
    _state.beginEditExpression(id);
    _state.setActiveExpression(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Face settings')),
      body: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Container(
                color: context.watch<AppState>().faceConfig.backgroundColor,
                child: const _FacePreview(),
              ),
            ),
            const VerticalDivider(width: 1, color: Colors.white24),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _controls(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _controls() {
    return [
      ..._expressionManager(),
      const Divider(color: Colors.white24),
      Text(
        'Editing: "${_state.expressionById(_editingId).name}"',
        style: const TextStyle(color: Colors.cyanAccent, fontSize: 13),
      ),
      const SizedBox(height: 8),
      // Shared background (whole screen + eyelid colour).
      _colorRow('Background', _d.backgroundColor, 'bg', (c) => _d.backgroundColor = c),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Blink'),
        value: _d.blinkEnabled,
        onChanged: (v) {
          setState(() => _d.blinkEnabled = v);
          _commit();
        },
      ),
      const Divider(color: Colors.white12),
      // Per-eye configuration. The split toggle is first.
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Separate eyes (wink, different colors, etc.)'),
        value: _d.perEye,
        onChanged: (v) {
          setState(() {
            _d.perEye = v;
            if (v) _d.rightEye = _d.leftEye.copy();
            _openColor = null;
          });
          _commit();
        },
      ),
      if (!_d.perEye)
        ..._eyeEditor('L', 'Both eyes', _d.leftEye, (n) {
          _d.leftEye = n;
          _d.rightEye = n.copy();
        })
      else ...[
        ..._eyeEditor('L', 'Left eye', _d.leftEye, (n) => _d.leftEye = n),
        const Divider(color: Colors.white24),
        ..._eyeEditor('R', 'Right eye', _d.rightEye, (n) => _d.rightEye = n),
      ],
    ];
  }

  // ----------------------------------------------------- expression manager
  List<Widget> _expressionManager() {
    final state = context.watch<AppState>();
    return [
      Row(
        children: [
          const Expanded(
            child: Text('Expressions', style: TextStyle(color: Colors.white)),
          ),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
            onPressed: () async {
              final id = await _state.addExpression();
              _state.setActiveExpression(id);
              setState(() {
                _editingId = id;
                _d = _state.expressionById(id).config.copy();
              });
            },
          ),
          IconButton(
            tooltip: 'Restore templates',
            icon: const Icon(Icons.restore, size: 20),
            onPressed: () => _state.restoreTemplates(),
          ),
        ],
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in state.expressions)
            InputChip(
              label: Text(
                '${e.name}${e.id == state.activeExpressionId ? ' ●' : ''}',
              ),
              selected: e.id == _editingId,
              onSelected: (_) => _editExpression(e.id),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Duplicate'),
            onPressed: () async {
              final id = await _state.duplicateExpression(_editingId);
              _state.setActiveExpression(id);
              setState(() {
                _editingId = id;
                _d = _state.expressionById(id).config.copy();
              });
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Rename'),
            onPressed: _renameDialog,
          ),
          if (state.expressions.length > 1)
            TextButton.icon(
              icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
              label: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent)),
              onPressed: () async {
                await _state.deleteExpression(_editingId);
                final next = _state.activeExpressionId;
                setState(() {
                  _editingId = next;
                  _d = _state.expressionById(next).config.copy();
                });
                _state.beginEditExpression(next);
              },
            ),
        ],
      ),
    ];
  }

  /// Rename the expression. Names are unique (ignoring case): `/expression`
  /// and smabo-web pick expressions by name.
  Future<void> _renameDialog() async {
    final ctrl =
        TextEditingController(text: _state.expressionById(_editingId).name);
    String? error;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          scrollable: true,
          title: const Text('Expression name'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
                helperText: '/expression selects it by this name',
                errorText: error),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                final err = await _state.renameExpression(_editingId, ctrl.text);
                if (err == null) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } else {
                  setLocal(() => error = err);
                }
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (done == true) setState(() {});
  }

  // ------------------------------------------------------------- eye editor
  /// Controls for one eye. [prefix] ('L'/'R') keys the colour rows; [setEye]
  /// replaces the eye in [_d] (used for "reset"). Only the controls relevant to
  /// the eye's [EyeShape] are shown.
  List<Widget> _eyeEditor(
      String prefix, String label, EyeAppearance e, ValueChanged<EyeAppearance> setEye) {
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Reset'),
              onPressed: () {
                setState(() => setEye(EyeAppearance(shape: e.shape)));
                _commit();
              },
            ),
          ],
        ),
      ),
      // ─────────── entire: shape, base colour and overall size.
      _sectionHeader('entire'),
      Row(
        children: [
          const SizedBox(
            width: 56,
            child: Text('Shape', style: TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: DropdownButton<EyeShape>(
              isExpanded: true,
              value: e.shape,
              dropdownColor: const Color(0xFF222222),
              items: const [
                DropdownMenuItem(value: EyeShape.round, child: Text('Round')),
                DropdownMenuItem(value: EyeShape.arc, child: Text('Arc (^)')),
                DropdownMenuItem(
                    value: EyeShape.heart, child: Text('Heart')),
                DropdownMenuItem(
                    value: EyeShape.swirl, child: Text('Swirl')),
                DropdownMenuItem(
                    value: EyeShape.squeeze, child: Text('Squeeze (><)')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  e.shape = v;
                  _openColor = null;
                });
                _commit();
              },
            ),
          ),
        ],
      ),
      if (e.shape == EyeShape.round)
        _colorRow('Sclera (white)', e.scleraColor, '$prefix:sclera',
            (c) => e.scleraColor = c)
      else
        _colorRow('Color', e.irisColor, '$prefix:iris',
            (c) => e.irisColor = c),
      _sizeRow('Size', e.scleraScale, 0.3, 1.6, (v) => e.scleraScale = v),
      _sizeRow('Rotation', e.shapeRotation, -180.0, 180.0,
          (v) => e.shapeRotation = v),

      // ─────────── iris (round only).
      if (e.shape == EyeShape.round) ...[
        _sectionHeader('Iris'),
        _colorRow('Color', e.irisColor, '$prefix:iris', (c) => e.irisColor = c),
        _sizeRow('Size', e.irisFrac, 0.1, 1.0, (v) {
          e.irisFrac = v;
          if (e.pupilFrac > e.irisFrac) e.pupilFrac = e.irisFrac;
        }),
      ],

      // ─────────── pupil (round only).
      if (e.shape == EyeShape.round) ...[
        _sectionHeader('pupil'),
        _colorRow('Color', e.pupilColor, '$prefix:pupil',
            (c) => e.pupilColor = c),
        _sizeRow('Size', e.pupilFrac.clamp(0.05, e.irisFrac), 0.05, e.irisFrac,
            (v) => e.pupilFrac = v),
      ],

      // ─────────── highlight (round and heart).
      if (e.usesHighlight) ...[
        _sectionHeader('highlight'),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Show'),
          value: e.highlightVisible,
          onChanged: (v) {
            setState(() => e.highlightVisible = v);
            _commit();
          },
        ),
        if (e.highlightVisible) ...[
          _colorRow('Color', e.highlightColor, '$prefix:highlight',
              (c) => e.highlightColor = c),
          if (e.shape == EyeShape.round) ...[
            _sizeRow('Size', e.highlightFrac, 0.05, 0.6,
                (v) => e.highlightFrac = v),
            _sizeRow('X', e.highlightX, -1.0, 1.0, (v) => e.highlightX = v),
            _sizeRow('Y', e.highlightY, -1.0, 1.0, (v) => e.highlightY = v),
          ],
        ],
      ],

      // ─────────── eyelid (rotation lives here per the design).
      _sectionHeader('Eyelid'),
      _sizeRow('Upper lid', e.lidTop, 0.0, 1.0, (v) => e.lidTop = v),
      _sizeRow('Lower lid', e.lidBottom, 0.0, 1.0, (v) => e.lidBottom = v),
      _sizeRow('Tilt', e.rotation, -180.0, 180.0, (v) => e.rotation = v),
    ];
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          text,
          style: const TextStyle(
              color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      );

  // -------------------------------------------------------------- colour
  /// One colour row with an inline picker.
  Widget _colorRow(
      String label, Color color, String key, ValueChanged<Color> setColor) {
    final open = _openColor == key;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child:
                    Text(label, style: const TextStyle(color: Colors.white70)),
              ),
              GestureDetector(
                onTap: () {
                  if (_openColor != null) _commit();
                  setState(() => _openColor = open ? null : key);
                },
                child: Container(
                  width: 30,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    border: Border.all(
                        color: open ? Colors.cyanAccent : Colors.white30,
                        width: open ? 2 : 1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (open) _inlineColorEditor(color, setColor),
      ],
    );
  }

  /// Inline colour editor with Wheel / RGB / HSV modes. Updates the preview
  /// live; persisted when the row is collapsed or the screen closes.
  Widget _inlineColorEditor(Color color, ValueChanged<Color> setColor) {
    void onChanged(Color c) {
      setState(() => setColor(c));
      _preview();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (var m = 0; m < 3; m++)
                ChoiceChip(
                  label: Text(['Wheel', 'RGB', 'HSV'][m]),
                  selected: _colorMode == m,
                  onSelected: (_) => setState(() => _colorMode = m),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_colorMode == 0)
            ColorPicker(
              pickerColor: color,
              onColorChanged: onChanged,
              enableAlpha: false,
              portraitOnly: true,
              colorPickerWidth: 260,
              pickerAreaHeightPercent: 0.6,
              labelTypes: const [ColorLabelType.hex],
              hexInputBar: true,
            )
          else
            SlidePicker(
              pickerColor: color,
              onColorChanged: onChanged,
              colorModel: _colorMode == 1 ? ColorModel.rgb : ColorModel.hsv,
              enableAlpha: false,
              showIndicator: true,
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- size
  Widget _sizeRow(String label, double value, double min, double max,
      ValueChanged<double> setter) {
    return _SizeField(
      label: label,
      value: value.clamp(min, max).toDouble(),
      min: min,
      max: max,
      onChanged: (v) {
        setState(() => setter(v));
        _preview();
      },
      onCommit: (v) {
        setState(() => setter(v));
        _commit();
      },
    );
  }
}
