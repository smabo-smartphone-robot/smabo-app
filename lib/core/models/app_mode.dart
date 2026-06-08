/// The top-level interaction modes, ordered as swipeable pages.
///
/// The face is the home page; swiping moves directly into the drive controller
/// and arm controller without a dedicated menu screen.
enum AppMode { face, drive, arm }

extension AppModeInfo on AppMode {
  String get title {
    switch (this) {
      case AppMode.face:
        return 'Face';
      case AppMode.drive:
        return 'Drive';
      case AppMode.arm:
        return 'Arm';
    }
  }

  int get pageIndex => index;
}

/// Eye behaviour within the face mode.
enum EyeMode { random, follow }
