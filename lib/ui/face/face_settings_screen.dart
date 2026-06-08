import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/models/face_config.dart';
import '../../state/app_state.dart';
import 'eye_painter.dart';

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
        'Editing: ID $_editingId  "${_state.expressionById(_editingId).name}"',
        style: const TextStyle(color: Colors.cyanAccent, fontSize: 13),
      ),
      const SizedBox(height: 8),
      // Shared background (whole screen + eyelid colour).
      _colorRow('Background', _d.backgroundColor, 'bg', (c) => _d.backgroundColor = c,
          getImage: () => _d.backgroundImage,
          setImage: (p) => _d.backgroundImage = p),
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
                '${e.id}: ${e.name}'
                '${e.id == state.activeExpressionId ? ' ●' : ''}',
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
          TextButton.icon(
            icon: const Icon(Icons.tag, size: 16),
            label: const Text('ID'),
            onPressed: _idDialog,
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

  Future<void> _renameDialog() async {
    final ctrl =
        TextEditingController(text: _state.expressionById(_editingId).name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Expression name'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('OK')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _state.renameExpression(_editingId, name.trim());
      setState(() {});
    }
  }

  /// Edit the expression's ID. Validates inline (positive, not already used).
  Future<void> _idDialog() async {
    final current = _state.expressionById(_editingId).id;
    final ctrl = TextEditingController(text: '$current');
    String? error;
    final newId = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          scrollable: true,
          title: const Text('Expression ID'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: 'ID', errorText: error),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final v = int.tryParse(ctrl.text.trim());
                if (v == null || v < 1) {
                  setLocal(() => error = 'Enter a positive integer');
                  return;
                }
                if (v != current &&
                    _state.expressions.any((e) => e.id == v)) {
                  setLocal(() => error = 'ID $v is already used');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (newId != null && newId != current) {
      final err = await _state.changeExpressionId(current, newId);
      if (err == null) {
        setState(() => _editingId = newId);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  // -------------------------------------------------------------- eye editor
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
      // ─────────── entire: shape, base colour/image and overall size.
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
                DropdownMenuItem(value: EyeShape.image, child: Text('Image')),
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
            (c) => e.scleraColor = c,
            getImage: () => e.scleraImage,
            setImage: (p) => e.setImageForSlot('sclera', p))
      else if (e.shape == EyeShape.image)
        _imageRow(e)
      else if (e.shape == EyeShape.heart)
        _colorRow('Color', e.irisColor, '$prefix:iris', (c) => e.irisColor = c,
            getImage: () => e.irisImage,
            setImage: (p) => e.setImageForSlot('iris', p))
      else
        _colorRow('Color', e.irisColor, '$prefix:iris',
            (c) => e.irisColor = c),
      _sizeRow('Size', e.scleraScale, 0.3, 1.6, (v) => e.scleraScale = v),
      _sizeRow('Rotation', e.shapeRotation, -180.0, 180.0,
          (v) => e.shapeRotation = v),

      // ─────────── iris (round only).
      if (e.shape == EyeShape.round) ...[
        _sectionHeader('Iris'),
        _colorRow('Color', e.irisColor, '$prefix:iris', (c) => e.irisColor = c,
            getImage: () => e.irisImage,
            setImage: (p) => e.setImageForSlot('iris', p)),
        _sizeRow('Size', e.irisFrac, 0.1, 1.0, (v) {
          e.irisFrac = v;
          if (e.pupilFrac > e.irisFrac) e.pupilFrac = e.irisFrac;
        }),
      ],

      // ─────────── pupil (round only).
      if (e.shape == EyeShape.round) ...[
        _sectionHeader('pupil'),
        _colorRow('Color', e.pupilColor, '$prefix:pupil',
            (c) => e.pupilColor = c,
            getImage: () => e.pupilImage,
            setImage: (p) => e.setImageForSlot('pupil', p)),
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
              (c) => e.highlightColor = c,
              getImage: e.shape == EyeShape.round ? () => e.highlightImage : null,
              setImage: e.shape == EyeShape.round
                  ? (p) => e.setImageForSlot('highlight', p)
                  : null),
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

  // -------------------------------------------------------------- image
  /// Picker row for the custom-image eye shape (no colour). Shows a hint until
  /// an image is chosen.
  Widget _imageRow(EyeAppearance e) {
    final path = e.irisImage;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path == null ? 'An image will be shown here' : 'Image set',
              style: TextStyle(
                color: path == null ? Colors.white38 : Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.image,
                size: 20,
                color: path != null ? Colors.cyanAccent : Colors.white54),
            tooltip: path != null ? 'Replace image' : 'Pick image',
            onPressed: () async {
              final x =
                  await ImagePicker().pickImage(source: ImageSource.gallery);
              if (x == null) return;
              setState(() => e.setImageForSlot('iris', x.path));
              _commit();
            },
          ),
          if (path != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18, color: Colors.redAccent),
              tooltip: 'Remove image',
              onPressed: () {
                setState(() => e.setImageForSlot('iris', null));
                _commit();
              },
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- colour
  /// One colour row with an inline picker. [setImage] (when given) adds an
  /// image button that overrides the colour for that element.
  Widget _colorRow(
      String label, Color color, String key, ValueChanged<Color> setColor,
      {String? Function()? getImage, void Function(String?)? setImage}) {
    final hasImage = getImage?.call() != null;
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
                  child: hasImage
                      ? const Icon(Icons.block, size: 14, color: Colors.white70)
                      : null,
                ),
              ),
              if (setImage != null)
                IconButton(
                  icon: Icon(Icons.image,
                      size: 20,
                      color: hasImage ? Colors.cyanAccent : Colors.white54),
                  tooltip:
                      hasImage ? 'Image set (tap to replace)' : 'Use image',
                  onPressed: () async {
                    final x = await ImagePicker()
                        .pickImage(source: ImageSource.gallery);
                    if (x == null) return;
                    setState(() => setImage(x.path));
                    _commit();
                  },
                ),
              if (hasImage && setImage != null)
                IconButton(
                  icon: const Icon(Icons.clear,
                      size: 18, color: Colors.redAccent),
                  tooltip: 'Remove image',
                  onPressed: () {
                    setState(() => setImage(null));
                    _commit();
                  },
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

/// Slider + text box for one numeric value. Slider drags preview live; the text
/// box accepts a precise value. Both commit when the gesture/edit finishes.
class _SizeField extends StatefulWidget {
  const _SizeField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onCommit,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  @override
  State<_SizeField> createState() => _SizeFieldState();
}

class _SizeFieldState extends State<_SizeField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value.toStringAsFixed(2));
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_SizeField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus &&
        (double.tryParse(_c.text) ?? double.nan) != widget.value) {
      _c.text = widget.value.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submitText(String s) {
    final v = double.tryParse(s);
    if (v != null) {
      widget.onCommit(v.clamp(widget.min, widget.max).toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child:
                Text(widget.label, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: Slider(
              min: widget.min,
              max: widget.max,
              value: widget.value.clamp(widget.min, widget.max).toDouble(),
              // Only move when the thumb itself is dragged, so scrolling the
              // list past the track (or a stray tap) does not change the value.
              allowedInteraction: SliderInteraction.slideThumb,
              onChanged: widget.onChanged,
              onChangeEnd: widget.onCommit,
            ),
          ),
          SizedBox(
            width: 56,
            child: TextField(
              controller: _c,
              focusNode: _focus,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(isDense: true),
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 13),
              onSubmitted: _submitText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated face preview: gentle wandering gaze + occasional blink, rendered
/// from the live [AppState.faceConfig] so edits show immediately.
class _FacePreview extends StatefulWidget {
  const _FacePreview();

  @override
  State<_FacePreview> createState() => _FacePreviewState();
}

class _FacePreviewState extends State<_FacePreview> {
  Timer? _timer;
  double _t = 0;
  double _blink = 1.0;
  double _nextBlinkAt = 3;
  double _blinkPhase = -1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _t += 0.016;
      if (_blink >= 1.0 && _t >= _nextBlinkAt) {
        _blinkPhase = 0;
      }
      if (_blinkPhase >= 0) {
        _blinkPhase += 0.016 / 0.18;
        _blink = _blinkPhase < 0.5
            ? 1 - _blinkPhase / 0.5
            : (_blinkPhase - 0.5) / 0.5;
        _blink = _blink.clamp(0.0, 1.0);
        if (_blinkPhase >= 1.0) {
          _blinkPhase = -1;
          _blink = 1.0;
          _nextBlinkAt = _t + 2 + (_t % 3);
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final fc = state.faceConfig;
    final gx = math.sin(_t * 0.9) * 0.9;
    final gy = math.sin(_t * 0.6) * 0.7;

    final screen = MediaQuery.of(context).size;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: screen.width,
        height: screen.height,
        child: CustomPaint(
          size: Size(screen.width, screen.height),
          painter: EyePainter(
            gazeX: gx,
            gazeY: gy,
            blink: fc.blinkEnabled ? _blink : 1.0,
            backgroundColor: fc.backgroundColor,
            leftEye: fc.displayLeft,
            rightEye: fc.displayRight,
            perEye: fc.perEye,
            backgroundImage: state.faceImages['background'],
            leftImages: state.eyeImages('L'),
            rightImages: state.eyeImages('R'),
          ),
        ),
      ),
    );
  }
}
