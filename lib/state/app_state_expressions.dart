part of 'app_state.dart';

/// Face expressions: pick, edit, add / duplicate / delete / rename, and load
/// the images they use.
extension AppStateExpressions on AppState {
  Future<void> setActiveExpression(int id) async {
    final resolved = settings.expressionById(id).id;
    if (settings.activeExpressionId == resolved && _previewConfig == null) {
      return;
    }
    settings.activeExpressionId = resolved;
    await settings.save();
    _notify();
    await _syncFaceImages();
  }

  Future<void> beginEditExpression(int id) async {
    _editingExpressionId = id;
    _previewConfig = settings.expressionById(id).config.copy();
    _notify();
    await _syncFaceImages();
  }

  Future<void> endEditExpression() async {
    _editingExpressionId = null;
    _previewConfig = null;
    _notify();
    await _syncFaceImages();
  }

  void previewFaceConfig(FaceConfig cfg) {
    _previewConfig = cfg.clamped();
    _notify();
  }

  Future<void> commitEditExpression(FaceConfig cfg) async {
    final clamped = cfg.clamped();
    _previewConfig = clamped;
    final id = _editingExpressionId;
    if (id != null) {
      settings.expressionById(id).config = clamped.copy();
      await settings.save();
    }
    _notify();
    await _syncFaceImages();
  }

  Future<int> addExpression() async {
    final id = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: id,
      name: 'Expression $id',
      config: FaceConfig(),
    ));
    await settings.save();
    await beginEditExpression(id);
    return id;
  }

  Future<int> duplicateExpression(int id) async {
    final src = settings.expressionById(id);
    final newId = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: newId,
      name: '${src.name} (copy)',
      config: src.config.copy(),
    ));
    await settings.save();
    await beginEditExpression(newId);
    return newId;
  }

  Future<void> deleteExpression(int id) async {
    if (settings.expressions.length <= 1) return;
    settings.expressions.removeWhere((e) => e.id == id);
    if (!settings.expressions.any((e) => e.id == settings.activeExpressionId)) {
      settings.activeExpressionId = settings.expressions.first.id;
    }
    if (_editingExpressionId == id) {
      _editingExpressionId = null;
      _previewConfig = null;
    }
    await settings.save();
    _notify();
    await _syncFaceImages();
  }

  Future<String?> changeExpressionId(int oldId, int newId) async {
    if (newId == oldId) return null;
    if (newId < 1) return 'ID must be a positive integer';
    if (settings.expressions.any((e) => e.id == newId)) {
      return 'ID $newId is already used';
    }
    final idx = settings.expressions.indexWhere((e) => e.id == oldId);
    if (idx < 0) return 'Expression not found';
    settings.expressions[idx].id = newId;
    if (settings.activeExpressionId == oldId) {
      settings.activeExpressionId = newId;
    }
    if (_editingExpressionId == oldId) _editingExpressionId = newId;
    settings.expressions.sort((a, b) => a.id.compareTo(b.id));
    await settings.save();
    _notify();
    return null;
  }

  Future<void> renameExpression(int id, String name) async {
    settings.expressionById(id).name = name;
    await settings.save();
    _notify();
  }

  Future<void> restoreTemplates() async {
    final present = settings.expressions.map((e) => e.id).toSet();
    for (final t in FaceExpression.templates()) {
      if (!present.contains(t.id)) settings.expressions.add(t);
    }
    await settings.save();
    _notify();
  }

  int _nextExpressionId() {
    var maxId = 0;
    for (final e in settings.expressions) {
      if (e.id > maxId) maxId = e.id;
    }
    return maxId + 1;
  }

  Map<String, ui.Image?> eyeImages(String side) {
    final out = <String, ui.Image?>{};
    for (final slot in EyeAppearance.slots) {
      out[slot] = faceImages['$side:$slot'];
    }
    return out;
  }

  Map<String, String?> _faceImagePaths() {
    final fc = faceConfig;
    final l = fc.displayLeft;
    final r = fc.displayRight;
    final out = <String, String?>{'background': fc.backgroundImage};
    for (final slot in EyeAppearance.slots) {
      out['L:$slot'] = l.imageForSlot(slot);
      out['R:$slot'] = r.imageForSlot(slot);
    }
    return out;
  }

  Future<void> _syncFaceImages() async {
    final paths = _faceImagePaths();
    for (final key in faceImages.keys.toList()) {
      if (!paths.containsKey(key)) {
        faceImages.remove(key);
        _loadedImagePaths.remove(key);
      }
    }
    for (final entry in paths.entries) {
      final key = entry.key;
      final path = entry.value;
      if (path == null) {
        if (faceImages[key] != null || _loadedImagePaths.containsKey(key)) {
          faceImages[key] = null;
          _loadedImagePaths.remove(key);
          _notify();
        }
      } else if (_loadedImagePaths[key] != path) {
        final img = await _loadImage(path);
        faceImages[key] = img;
        _loadedImagePaths[key] = path;
        _notify();
      }
    }
  }

  Future<ui.Image?> _loadImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      _addLog('⚠️ Could not load image: $path');
      return null;
    }
  }
}
