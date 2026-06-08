import 'dart:convert';

import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// A structured editor for the live ESP32 configuration, fetched via
/// `get_config` and pushed back with `set_config` / `set_mode`.
///
/// Sections mirror `~/esp32_robot/config.py` (DEFAULTS) and are grouped by the
/// reflection rules in `DESIGN.md`:
///   - immediate / subsystem-restart values are edited freely;
///   - pin/bus/WiFi values are under a collapsed "advanced" section with a
///     reboot warning, because changing them resets the board (and WiFi can
///     drop connectivity).
///
/// Each field sends a minimal nested patch so the firmware deep-merges it.
class Esp32ConfigEditor extends StatelessWidget {
  const Esp32ConfigEditor({super.key, required this.state});

  final AppState state;

  Map<String, dynamic> get _cfg => state.esp32Config ?? const {};

  Map<String, dynamic> _map(String key) =>
      (_cfg[key] as Map?)?.cast<String, dynamic>() ?? const {};

  @override
  Widget build(BuildContext context) {
    final cfg = state.esp32Config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('Get config'),
              // Explicit refresh shows the device's real values.
              onPressed: () => state.requestEsp32Config(fresh: true),
            ),
            const SizedBox(width: 8),
            if (cfg == null)
              const Expanded(
                child: Text('Not loaded (ESP32 not connected?)',
                    style: TextStyle(color: Colors.white38)),
              ),
          ],
        ),
        if (cfg != null) ...[
          const SizedBox(height: 8),
          _modes(),
          _servosSection(context),
          _dcDrive(),
          _encoder(),
          _websocket(),
          _advanced(context),
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('Full config (JSON)'),
            childrenPadding: const EdgeInsets.all(8),
            children: [
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(cfg),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------- modes
  Widget _modes() {
    final modes = _map('modes');
    return _group('Modes', [
      _boolTile('servos', modes['servos'] == true,
          (v) => state.setEsp32Modes({'servos': v})),
      _boolTile('dc_drive', modes['dc_drive'] == true,
          (v) => state.setEsp32Modes({'dc_drive': v})),
      _boolTile('encoder_drive', modes['encoder_drive'] == true,
          (v) => state.setEsp32Modes({'encoder_drive': v})),
    ]);
  }

  // ---- All servo-related settings combined under one "Servos" section ----
  Widget _servosSection(BuildContext context) {
    return _group('Servos', [
      _subLabel('General'),
      ..._servosGeneralItems(),
      _subLabel('Per joint'),
      ..._servoJointItems(context),
      _subLabel('Motion: manual / random'),
      ..._motionItems(context),
    ]);
  }

  List<Widget> _servosGeneralItems() {
    final s = _map('servos');
    final randomOn = (s['behavior'] as String?) == 'random';
    return [
      _boolTile(
        'Enable random (auto) motion',
        randomOn,
        (v) => state.setEsp32Config({
          'servos': {'behavior': v ? 'random' : 'manual'}
        }),
      ),
      const Padding(
        padding: EdgeInsets.only(bottom: 4),
        child: Text(
          'Master switch for auto motion. Which servos move automatically is '
          'set per servo below (Manual vs a random group).',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
      _ConfigField(
        label: 'joint_states_rate (Hz, 0=off)',
        value: s['joint_states_rate'],
        onSubmit: (v) => state.setEsp32Config({
          'servos': {'joint_states_rate': v}
        }),
      ),
    ];
  }

  // ----------------------------------------------------- per-joint specs
  List<Widget> _servoJointItems(BuildContext context) {
    final joints = _map('servos')['joints'];
    if (joints is! Map) return const [];
    final jmap = joints.cast<String, dynamic>();
    final names = state.orderedServoNames();
    return [
      const Text('Use ▲▼ to reorder (affects this list, motion assignment and '
          'the arm controller).',
          style: TextStyle(color: Colors.white38, fontSize: 12)),
      for (var i = 0; i < names.length; i++)
        if (jmap[names[i]] is Map)
          ExpansionTile(
            key: ValueKey(names[i]),
            tilePadding: EdgeInsets.zero,
            title: Text(names[i], style: const TextStyle(color: Colors.white70)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                  tooltip: 'Move up',
                  onPressed: i == 0 ? null : () => state.moveServo(names[i], -1),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  tooltip: 'Move down',
                  onPressed: i == names.length - 1
                      ? null
                      : () => state.moveServo(names[i], 1),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 20),
                  tooltip: 'Remove servo',
                  onPressed: () => _confirmRemoveJoint(context, names[i]),
                ),
              ],
            ),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children:
                _jointFields(names[i], (jmap[names[i]] as Map).cast<String, dynamic>()),
          ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add servo'),
          onPressed: () => _addJointDialog(context),
        ),
      ),
    ];
  }

  Future<void> _addJointDialog(BuildContext context) async {
    // Suggest the next arm_joint_N name.
    final joints =
        (_map('servos')['joints'] as Map?)?.cast<String, dynamic>() ?? const {};
    var n = 1;
    while (joints.containsKey('arm_joint_$n')) {
      n++;
    }
    final controller = TextEditingController(text: 'arm_joint_$n');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add servo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Joint name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (joints.containsKey(name)) return; // already exists
    state.addEsp32Joint(name);
  }

  Future<void> _confirmRemoveJoint(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "$name"?'),
        content: const Text(
            'This deletes the servo from the ESP32 config and restarts the '
            'servo subsystem.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) state.removeEsp32Joint(name);
  }

  List<Widget> _jointFields(String joint, Map<String, dynamic> spec) {
    void send(String field, num v) => state.setEsp32Config({
          'servos': {
            'joints': {
              joint: {field: v}
            }
          }
        });
    return [
      _ConfigField(
          label: 'channel',
          value: spec['channel'],
          isInt: true,
          onSubmit: (v) => send('channel', v)),
      _ConfigField(
          label: 'min_angle (deg)',
          value: spec['min_angle'],
          onSubmit: (v) => send('min_angle', v)),
      _ConfigField(
          label: 'max_angle (deg)',
          value: spec['max_angle'],
          onSubmit: (v) => send('max_angle', v)),
      _ConfigField(
          label: 'init_angle (deg)',
          value: spec['init_angle'],
          onSubmit: (v) => send('init_angle', v)),
      _ConfigField(
          label: 'max_speed (deg/s, 0=instant)',
          value: spec['max_speed'],
          onSubmit: (v) => send('max_speed', v)),
      _ConfigField(
          label: 'min_us',
          value: spec['min_us'],
          isInt: true,
          onSubmit: (v) => send('min_us', v)),
      _ConfigField(
          label: 'max_us',
          value: spec['max_us'],
          isInt: true,
          onSubmit: (v) => send('max_us', v)),
    ];
  }

  // ----------------------------------------- motion: manual / random
  List<Widget> _motionItems(BuildContext context) {
    final names = state.orderedServoNames();
    final groups = state.esp32RandomGroups();
    final groupNames = [
      for (final g in groups)
        if ((g['name']?.toString() ?? '').isNotEmpty) g['name'].toString(),
    ];

    return [
      const Text(
        'Each servo is either Manual (you control it) or assigned to a random '
        'group (auto motion). Servos in the same group move together at random '
        'times — angles are independent. Manual and random run at the same time '
        '(turn on "Enable random motion" above).',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      ),
      const SizedBox(height: 8),
      for (final name in names) _motionRow(name, groupNames),
      const Divider(color: Colors.white24),
      const Text('Random groups (timing)',
          style: TextStyle(color: Colors.white54)),
      const SizedBox(height: 4),
      for (final g in groups) _groupRow(g),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add group'),
          onPressed: () => _addGroupDialog(context),
        ),
      ),
    ];
  }

  Widget _motionRow(String joint, List<String> groupNames) {
    final current = state.esp32JointGroup(joint); // null = manual
    final value = current != null && groupNames.contains(current)
        ? current
        : '__manual__';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(joint, style: const TextStyle(color: Colors.white70)),
          ),
          DropdownButton<String>(
            value: value,
            dropdownColor: const Color(0xFF111111),
            items: [
              const DropdownMenuItem(value: '__manual__', child: Text('Manual')),
              for (final gn in groupNames)
                DropdownMenuItem(value: gn, child: Text('Random: $gn')),
            ],
            onChanged: (v) {
              if (v == null) return;
              state.assignJointMotion(joint, v == '__manual__' ? null : v);
            },
          ),
        ],
      ),
    );
  }

  Widget _groupRow(Map<String, dynamic> g) {
    final name = g['name']?.toString() ?? '';
    final interval = (g['interval'] as List?)?.cast<num>() ?? const [1, 3];
    final members = (g['joints'] as List?)?.join(', ') ?? '';
    final lo = interval.isNotEmpty ? interval[0] : 1;
    final hi = interval.length > 1 ? interval[1] : 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(members.isEmpty ? '$name  (empty)' : '$name  [$members]',
                  style: const TextStyle(color: Colors.white60, fontSize: 13)),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 18),
              tooltip: 'Remove group',
              onPressed: () => state.removeEsp32RandomGroup(name),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _ConfigField(
                label: 'interval min (s)',
                value: lo,
                onSubmit: (v) =>
                    state.setEsp32GroupInterval(name, v.toDouble(), hi.toDouble()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ConfigField(
                label: 'interval max (s)',
                value: hi,
                onSubmit: (v) =>
                    state.setEsp32GroupInterval(name, lo.toDouble(), v.toDouble()),
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Lifelike tuning',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            const Text(
              'Higher saccade = more quick glances. Larger drift = bigger idle '
              'wander. Center pull = how strongly it returns to rest. Drift '
              'speed = slow-wander speed (fraction of max_speed). Long-pause = '
              'chance of an occasional long, still settle.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            _groupParam(name, 'saccade_prob', g['saccade_prob'], 0.18),
            _groupParam(name, 'drift', g['drift'], 0.07),
            _groupParam(name, 'center_pull', g['center_pull'], 0.12),
            _groupParam(name, 'drift_speed', g['drift_speed'], 0.4),
            _groupParam(name, 'long_pause_prob', g['long_pause_prob'], 0.22),
          ],
        ),
        const Divider(color: Colors.white12),
      ],
    );
  }

  Widget _groupParam(String group, String key, dynamic value, double dflt) {
    return _ConfigField(
      label: '$key (0–1)',
      value: value ?? dflt,
      onSubmit: (v) => state.setEsp32GroupParam(group, key, v),
    );
  }

  Future<void> _addGroupDialog(BuildContext context) async {
    final groups = state.esp32RandomGroups();
    var n = 1;
    while (groups.any((g) => g['name'] == 'group$n')) {
      n++;
    }
    final controller = TextEditingController(text: 'group$n');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add random group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    state.addEsp32RandomGroup(name);
  }

  // --------------------------------------------------------- DC drive
  Widget _dcDrive() {
    final dc = _map('dc');
    void send(String f, num v) => state.setEsp32Config({
          'dc': {f: v}
        });
    return _group('Drive (DC)', [
      _ConfigField(
          label: 'max_linear (m/s)',
          value: dc['max_linear'],
          onSubmit: (v) => send('max_linear', v)),
      _ConfigField(
          label: 'max_angular (rad/s)',
          value: dc['max_angular'],
          onSubmit: (v) => send('max_angular', v)),
      _ConfigField(
          label: 'wheel_radius (m)',
          value: dc['wheel_radius'],
          onSubmit: (v) => send('wheel_radius', v)),
      _ConfigField(
          label: 'wheel_separation (m)',
          value: dc['wheel_separation'],
          onSubmit: (v) => send('wheel_separation', v)),
      _ConfigField(
          label: 'pwm_freq (Hz)',
          value: dc['pwm_freq'],
          isInt: true,
          onSubmit: (v) => send('pwm_freq', v)),
      _ConfigField(
          label: 'cmd_timeout (s)',
          value: dc['cmd_timeout'],
          onSubmit: (v) => send('cmd_timeout', v)),
      _boolTile('invert_left', dc['invert_left'] == true,
          (v) => state.setEsp32Config({'dc': {'invert_left': v}})),
      _boolTile('invert_right', dc['invert_right'] == true,
          (v) => state.setEsp32Config({'dc': {'invert_right': v}})),
    ]);
  }

  // --------------------------------------------------- encoder / odom
  Widget _encoder() {
    final enc = _map('encoder');
    final cov = (enc['covariance'] as Map?)?.cast<String, dynamic>() ?? const {};
    void send(String f, num v) => state.setEsp32Config({
          'encoder': {f: v}
        });
    void sendCov(String f, num v) => state.setEsp32Config({
          'encoder': {
            'covariance': {f: v}
          }
        });
    return _group('Encoder / Odometry', [
      _ConfigField(
          label: 'cpr (counts/rev)',
          value: enc['cpr'],
          isInt: true,
          onSubmit: (v) => send('cpr', v)),
      _ConfigField(
          label: 'publish_rate (Hz)',
          value: enc['publish_rate'],
          onSubmit: (v) => send('publish_rate', v)),
      _ConfigField(
          label: 'odom_frame',
          value: enc['odom_frame'],
          isString: true,
          onSubmitString: (v) => state.setEsp32Config({
                'encoder': {'odom_frame': v}
              })),
      _ConfigField(
          label: 'base_frame',
          value: enc['base_frame'],
          isString: true,
          onSubmitString: (v) => state.setEsp32Config({
                'encoder': {'base_frame': v}
              })),
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 4),
        child: Text('covariance (diagonal variances)',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
      _ConfigField(
          label: 'pose_xx (m²)',
          value: cov['pose_xx'],
          onSubmit: (v) => sendCov('pose_xx', v)),
      _ConfigField(
          label: 'pose_yy (m²)',
          value: cov['pose_yy'],
          onSubmit: (v) => sendCov('pose_yy', v)),
      _ConfigField(
          label: 'pose_aa (rad²)',
          value: cov['pose_aa'],
          onSubmit: (v) => sendCov('pose_aa', v)),
      _ConfigField(
          label: 'twist_vv ((m/s)²)',
          value: cov['twist_vv'],
          onSubmit: (v) => sendCov('twist_vv', v)),
      _ConfigField(
          label: 'twist_ww ((rad/s)²)',
          value: cov['twist_ww'],
          onSubmit: (v) => sendCov('twist_ww', v)),
    ]);
  }

  // --------------------------------------------------------- websocket
  Widget _websocket() {
    final ws = _map('ws');
    return _group('WebSocket', [
      _ConfigField(
        label: 'ws.port (reboot on change)',
        value: ws['port'],
        isInt: true,
        onSubmit: (v) => state.setEsp32Config({
          'ws': {'port': v}
        }),
      ),
    ]);
  }

  // -------------------------------------- advanced: pins / bus / wifi
  // These all reboot the ESP32, so edits are STAGED locally and applied
  // together with a single reboot via the "Apply" button.
  Widget _advanced(BuildContext context) {
    final i2c = _map('i2c');
    final pca = _map('pca9685');
    final dcPins = (_map('dc')['pins'] as Map?)?.cast<String, dynamic>() ?? const {};
    final encL = (_map('encoder')['left'] as Map?)?.cast<String, dynamic>() ?? const {};
    final encR = (_map('encoder')['right'] as Map?)?.cast<String, dynamic>() ?? const {};
    final wifi = _map('wifi');
    final staged = state.hasEsp32AdvancedStage;

    // Show the staged value if present, else the device value.
    dynamic shown(List<String> path, dynamic device) =>
        state.esp32StagedAt(path) ?? device;
    // Stage a nested edit (no send).
    void stage(List<String> path, dynamic v) =>
        state.stageEsp32Advanced(_nest(path, v));

    Widget intField(String label, List<String> path, dynamic device) =>
        _ConfigField(
          label: label,
          value: shown(path, device),
          isInt: true,
          onSubmit: (v) => stage(path, v),
        );

    return ExpansionTile(
      title: const Text('Advanced: pins / bus / WiFi  ⚠️ reboot',
          style: TextStyle(color: Colors.orangeAccent)),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Edits here are staged, then applied together with one reboot '
            '(~3-5 s) via "Apply". Changing WiFi can make the board unreachable, '
            'so it is best to set WiFi once over USB (config.json).',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
          ),
        ),
        _subLabel('I2C'),
        intField('sda', ['i2c', 'sda'], i2c['sda']),
        intField('scl', ['i2c', 'scl'], i2c['scl']),
        intField('freq (Hz)', ['i2c', 'freq'], i2c['freq']),
        _subLabel('PCA9685'),
        intField('address', ['pca9685', 'address'], pca['address']),
        intField('freq (Hz)', ['pca9685', 'freq'], pca['freq']),
        _subLabel('DC motor pins'),
        for (final p in ['stby', 'ain1', 'ain2', 'pwma', 'bin1', 'bin2', 'pwmb'])
          intField(p, ['dc', 'pins', p], dcPins[p]),
        _subLabel('Encoder pins'),
        intField('left.a', ['encoder', 'left', 'a'], encL['a']),
        intField('left.b', ['encoder', 'left', 'b'], encL['b']),
        intField('right.a', ['encoder', 'right', 'a'], encR['a']),
        intField('right.b', ['encoder', 'right', 'b'], encR['b']),
        _subLabel('WiFi  ⚠️ may drop the connection'),
        _ConfigField(
            label: 'ssid',
            value: shown(['wifi', 'ssid'], wifi['ssid']),
            isString: true,
            onSubmitString: (v) => stage(['wifi', 'ssid'], v)),
        _ConfigField(
            label: 'password',
            value: shown(['wifi', 'password'], wifi['password']),
            isString: true,
            onSubmitString: (v) => stage(['wifi', 'password'], v)),
        _ConfigField(
            label: 'hostname',
            value: shown(['wifi', 'hostname'], wifi['hostname']),
            isString: true,
            onSubmitString: (v) => stage(['wifi', 'hostname'], v)),
        const SizedBox(height: 10),
        Row(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Apply (reboots ESP32)'),
              onPressed: staged ? state.applyEsp32Advanced : null,
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: staged ? state.discardEsp32Advanced : null,
              child: const Text('Discard'),
            ),
          ],
        ),
        if (staged)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Staged changes are not sent until you press Apply.',
                style: TextStyle(color: Colors.amber, fontSize: 12)),
          ),
      ],
    );
  }

  /// Build a nested map for [path] ending in [value]
  /// (e.g. ['dc','pins','pwma'], 33 → {dc:{pins:{pwma:33}}}).
  Map<String, dynamic> _nest(List<String> path, dynamic value) {
    dynamic cur = value;
    for (var i = path.length - 1; i >= 0; i--) {
      cur = <String, dynamic>{path[i]: cur};
    }
    return cur as Map<String, dynamic>;
  }

  // ------------------------------------------------------------ helpers
  /// A configuration sub-section: a coloured, divided header makes the breaks
  /// between ESP32 settings groups (modes, servos, drive, …) easy to scan.
  Widget _group(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(title,
            style: const TextStyle(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
        const Divider(color: Color(0x55FFA726)), // orangeAccent, faded
        ...children,
      ],
    );
  }

  Widget _subLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(t, style: const TextStyle(color: Colors.white54, fontSize: 13)),
      );

  Widget _boolTile(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// A single numeric (or string) config field with a send button. Keeps its own
/// controller so typing is not interrupted, and re-seeds when the upstream
/// value changes (e.g. after a fresh `get_config`) while not being edited.
class _ConfigField extends StatefulWidget {
  const _ConfigField({
    required this.label,
    required this.value,
    this.isInt = false,
    this.isString = false,
    this.onSubmit,
    this.onSubmitString,
  });

  final String label;
  final dynamic value;
  final bool isInt;
  final bool isString;
  final void Function(num)? onSubmit;
  final void Function(String)? onSubmitString;

  @override
  State<_ConfigField> createState() => _ConfigFieldState();
}

class _ConfigFieldState extends State<_ConfigField> {
  late final TextEditingController _c =
      TextEditingController(text: _format(widget.value));
  final FocusNode _focus = FocusNode();

  String _format(dynamic v) => v == null ? '' : '$v';

  @override
  void didUpdateWidget(_ConfigField old) {
    super.didUpdateWidget(old);
    // Refresh from upstream only when the user is not actively editing.
    if (!_focus.hasFocus && _format(widget.value) != _c.text) {
      _c.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.isString) {
      widget.onSubmitString?.call(_c.text);
    } else {
      final v = widget.isInt ? int.tryParse(_c.text) : double.tryParse(_c.text);
      if (v != null) widget.onSubmit?.call(v);
    }
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 800),
        content: Text('Sent ${widget.label}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _c,
              focusNode: _focus,
              keyboardType: widget.isString
                  ? TextInputType.text
                  : TextInputType.numberWithOptions(
                      decimal: !widget.isInt, signed: true),
              decoration: InputDecoration(
                labelText: widget.label,
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, size: 18),
            tooltip: 'Send',
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
