import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'face/face_screen.dart';
import 'settings/settings_screen.dart';
import 'widgets/sensor_toggle_bar.dart';
import 'widgets/status_bar.dart';

/// Root scaffold: the face screen with a thin status bar (connection + voice)
/// and a sensor toggle bar overlaid. Both overlays auto-hide after a delay
/// when [AppSettings.faceAutoHide] is on.
class HomePager extends StatefulWidget {
  const HomePager({super.key});

  @override
  State<HomePager> createState() => _HomePagerState();
}

class _HomePagerState extends State<HomePager> {
  StreamSubscription<String>? _connSub;

  @override
  void initState() {
    super.initState();
    // Show a transient banner whenever the brain endpoint connects or disconnects.
    _connSub = context.read<AppState>().connectionEvents.listen((msg) {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final visible = state.chromeVisible;
    return Scaffold(
      body: Stack(
        children: [
          const FaceScreen(),

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
