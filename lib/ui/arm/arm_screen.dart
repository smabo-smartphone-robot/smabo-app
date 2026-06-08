import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// Robot arm controller: a slider per **manually-controlled servo**, streaming
/// `trajectory_msgs/JointTrajectory` to the ESP32 on `/servo/command`.
///
/// The joint list is derived live from the ESP32 config (`servos.joints`),
/// excluding any joint that belongs to a `random_groups` entry — those move on
/// their own and are not for manual control. Each slider uses that joint's
/// `min_angle`/`max_angle`; values are sent in radians (ROS standard).
class ArmScreen extends StatefulWidget {
  const ArmScreen({super.key});

  @override
  State<ArmScreen> createState() => _ArmScreenState();
}

class _ArmScreenState extends State<ArmScreen> {
  final Map<String, double> _deg = {}; // joint → commanded angle (deg)

  Timer? _throttle;
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.setEsp32Modes({'servos': true}); // ensure servos run
      state.requestEsp32Config(); // populate the joint list
    });
  }

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  void _onChanged(String joint, double deg) {
    setState(() => _deg[joint] = deg);
    _pending.add(joint);
    // Responsiveness-first: short send throttle (~33 Hz).
    _throttle ??= Timer(const Duration(milliseconds: 30), _flush);
  }

  void _flush() {
    _throttle = null;
    if (_pending.isEmpty) return;
    final names = _pending.toList();
    final rads = names.map((j) => _deg[j]! * math.pi / 180.0).toList();
    _pending.clear();
    // time_from_start = 0 → the ESP32 applies it on the next tick and moves as
    // fast as each servo's max_speed allows (most responsive).
    context.read<AppState>().sendArmCommand(names, rads, timeFromStart: 0.0);
  }

  /// Manually-controlled joints from the live config — every `servos.joints`
  /// entry not present in any `random_groups[*].joints` — in the app's saved
  /// servo display order.
  List<_JointSpec> _manualJoints(AppState state) {
    final servos =
        (state.esp32Config?['servos'] as Map?)?.cast<String, dynamic>();
    final joints = (servos?['joints'] as Map?)?.cast<String, dynamic>();
    if (joints == null || joints.isEmpty) return const [];

    final grouped = <String>{};
    final groups = servos?['random_groups'];
    if (groups is List) {
      for (final g in groups) {
        final gj = g is Map ? g['joints'] : null;
        if (gj is List) grouped.addAll(gj.map((e) => '$e'));
      }
    }

    final out = <_JointSpec>[];
    for (final name in state.orderedServoNames()) {
      if (grouped.contains(name)) continue;
      final m = (joints[name] as Map?)?.cast<String, dynamic>() ?? const {};
      out.add(_JointSpec(
        name: name,
        min: (m['min_angle'] as num?)?.toDouble() ?? -90,
        max: (m['max_angle'] as num?)?.toDouble() ?? 90,
        init: (m['init_angle'] as num?)?.toDouble() ?? 0,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final joints = _manualJoints(state);

    return GestureDetector(
      // Double-tap reveals the hidden overlays (single touches move the arm).
      behavior: HitTestBehavior.translucent,
      onDoubleTap: () => context.read<AppState>().pokeChrome(),
      child: Container(
      color: const Color(0xFF0A0612),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            const Text('Arm controller (JointTrajectory)',
                style: TextStyle(color: Colors.white54)),
            Expanded(
              child: joints.isEmpty
                  ? _empty(state)
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ListView(
                        children: [
                          for (final j in joints) _jointSlider(j),
                        ],
                      ),
                    ),
            ),
            if (joints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextButton.icon(
                  icon: const Icon(Icons.home),
                  label: const Text('Home position'),
                  onPressed: () {
                    setState(() {
                      for (final j in joints) {
                        _deg[j.name] = j.init;
                      }
                    });
                    context.read<AppState>().sendArmCommand(
                          [for (final j in joints) j.name],
                          [for (final j in joints) j.init * math.pi / 180.0],
                          timeFromStart: 1.0,
                        );
                  },
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _empty(AppState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No manually-controlled servos found.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 4),
          const Text(
            'Servos in random-motion groups are excluded.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Get config'),
            onPressed: state.requestEsp32Config,
          ),
        ],
      ),
    );
  }

  Widget _jointSlider(_JointSpec j) {
    final value = (_deg[j.name] ?? j.init).clamp(j.min, j.max);
    final divisions = math.max(1, (j.max - j.min).round());
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(j.name, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          child: Slider(
            min: j.min,
            max: j.max,
            value: value.toDouble(),
            label: '${value.round()}°',
            divisions: divisions,
            onChanged: (v) => _onChanged(j.name, v),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text('${value.round()}°',
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.cyanAccent)),
        ),
      ],
    );
  }
}

/// A manually-controlled joint and its angle range (degrees).
class _JointSpec {
  const _JointSpec({
    required this.name,
    required this.min,
    required this.max,
    required this.init,
  });
  final String name;
  final double min;
  final double max;
  final double init;
}
