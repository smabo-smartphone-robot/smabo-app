import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../widgets/joystick.dart';

/// Mobile robot controller: a joystick that streams `geometry_msgs/Twist` to
/// the ESP32 on `/cmd_vel`.
///
/// The joystick's forward axis maps to `linear.x` and the lateral axis to
/// `angular.z`. Commands are sent at a fixed rate while engaged (and a final
/// zero on release) so the ESP32 dead-man watchdog keeps the motors alive.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  double _x = 0, _y = 0;
  Timer? _sendTimer;
  late final AppState _app;

  // Scale factors — keep within typical ESP32 dc.max_linear / max_angular.
  static const double _maxLinear = 0.30; // m/s
  static const double _maxAngular = 1.50; // rad/s

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    // 10 Hz command stream (well within the 0.5 s dead-man timeout).
    // Vertical = forward/back (translation), horizontal = turn. With the stick
    // centred vertically (_y == 0) it is pure rotation → spins in place. When
    // reversing (_y < 0) the turn is inverted so left/right matches the driver's
    // view (natural reverse steering, like a car).
    _sendTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      // Small vertical dead-zone so a near-horizontal stick is pure rotation.
      final fwd = _y.abs() < 0.12 ? 0.0 : _y;
      final linear = fwd * _maxLinear;
      var angular = -_x * _maxAngular;
      // Invert the turn only when CLEARLY reversing — using a threshold (not
      // just _y < 0) avoids the spin direction flipping when the stick is swung
      // full left/right and the vertical component briefly dips negative.
      if (fwd < -0.2) angular = -angular;
      _app.sendCmdVel(linear, angular);
    });
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    // Best-effort stop on leaving + release any page lock.
    _app.sendCmdVel(0, 0);
    _app.setPageLocked(false);
    super.dispose();
  }

  void _ensureDriveMode() {
    // Switch the ESP32 to dc_drive when entering this controller.
    _app.setEsp32Modes({'dc_drive': true});
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Double-tap reveals the hidden overlays (single touches drive the robot).
      behavior: HitTestBehavior.translucent,
      onDoubleTap: () => _app.pokeChrome(),
      child: Container(
      color: const Color(0xFF06121A),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            const Text('Drive controller (cmd_vel)',
                style: TextStyle(color: Colors.white54)),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Telemetry from /odom.
                  _Telemetry(),
                  // Lock page swiping while touching the joystick so the drag
                  // is not stolen as a swipe to the adjacent mode.
                  Listener(
                    onPointerDown: (_) => _app.setPageLocked(true),
                    onPointerUp: (_) => _app.setPageLocked(false),
                    onPointerCancel: (_) => _app.setPageLocked(false),
                    child: Joystick(
                      label: 'Throttle / Turn',
                      onChanged: (x, y) {
                        if ((_x == 0 && _y == 0) && (x != 0 || y != 0)) {
                          _ensureDriveMode();
                        }
                        _x = x;
                        _y = y;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _Telemetry extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final odom = context.select<AppState, dynamic>((s) => s.odom);
    final tx = odom == null ? '—' : odom.linearX.toStringAsFixed(2);
    final az = odom == null ? '—' : odom.angularZ.toStringAsFixed(2);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Odometry (/odom)',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 8),
        Text('v: $tx m/s',
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 18)),
        Text('ω: $az rad/s',
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 18)),
      ],
    );
  }
}
