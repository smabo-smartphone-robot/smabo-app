part of 'face_settings_screen.dart';

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
