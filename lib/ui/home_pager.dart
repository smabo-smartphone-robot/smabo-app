import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/app_mode.dart';
import '../state/app_state.dart';
import 'arm/arm_screen.dart';
import 'drive/drive_screen.dart';
import 'face/face_screen.dart';
import 'settings/settings_screen.dart';
import 'widgets/sensor_toggle_bar.dart';
import 'widgets/status_bar.dart';

/// Root scaffold: a horizontally-swipeable [PageView] over the three modes
/// (face → drive → arm), with no separate mode-selection screen.
///
/// A thin status bar (connection + voice) and a sensor toggle bar overlay
/// every page so sensors can be switched from any mode.
class HomePager extends StatefulWidget {
  const HomePager({super.key});

  @override
  State<HomePager> createState() => _HomePagerState();
}

class _HomePagerState extends State<HomePager> {
  late final PageController _controller;
  StreamSubscription<String>? _connSub;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _controller = PageController(initialPage: state.mode.pageIndex);
    // Show a transient banner whenever an endpoint connects or disconnects.
    _connSub = state.connectionEvents.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final visible = state.chromeVisible;
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _controller,
            physics: state.pageLocked
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: (i) => state.setMode(AppMode.values[i]),
            children: const [
              FaceScreen(),
              DriveScreen(),
              ArmScreen(),
            ],
          ),

          // Top status overlay.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _chrome(
              visible,
              Listener(
                onPointerDown: (_) => state.pokeChrome(),
                child: const SafeArea(child: StatusBar()),
              ),
            ),
          ),

          // Bottom sensor toggles + settings button.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _chrome(
              visible,
              Listener(
                onPointerDown: (_) => state.pokeChrome(),
                child: SafeArea(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(child: SensorToggleBar()),
                      IconButton(
                        icon: const Icon(Icons.settings),
                        tooltip: 'Settings',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Page indicator dots.
          Positioned(
            bottom: 56,
            left: 0,
            right: 0,
            child: _chrome(
              visible,
              _PageDots(index: state.mode.pageIndex, count: 3),
            ),
          ),
        ],
      ),
    );
  }

  /// Wrap an overlay so it fades out and stops receiving touches when the
  /// chrome is hidden (face-screen auto-hide).
  Widget _chrome(bool visible, Widget child) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 350),
        child: child,
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.index, required this.count});
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? Colors.cyanAccent : Colors.white24,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
