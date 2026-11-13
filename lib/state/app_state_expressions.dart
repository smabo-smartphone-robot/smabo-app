part of 'app_state.dart';

/// Face expressions: pick, edit, add / duplicate / delete / rename.
extension AppStateExpressions on AppState {
  Future<void> setActiveExpression(int id) async {
    final resolved = settings.expressionById(id).id;
    if (settings.activeExpressionId == resolved && _previewConfig == null) {
      return;
    }
    settings.activeExpressionId = resolved;
    await _saveSettings();
    _notify();
  }

  /// Show the expression called [name] (ignoring case). False if there is none.
  Future<bool> setActiveExpressionByName(String name) async {
    final e = settings.expressionByName(name);
    if (e == null) return false;
    await setActiveExpression(e.id);
    return true;
  }

  List<String> _namesExcept(int? id) =>
      [for (final e in settings.expressions) if (e.id != id) e.name];

  Future<void> beginEditExpression(int id) async {
    _editingExpressionId = id;
    _previewConfig = settings.expressionById(id).config.copy();
    _notify();
  }

  Future<void> endEditExpression() async {
    _editingExpressionId = null;
    _previewConfig = null;
    _notify();
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
      await _saveSettings();
    }
    _notify();
  }

  Future<int> addExpression() async {
    final id = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: id,
      name: uniqueExpressionName('Expression', _namesExcept(null)),
      config: FaceConfig(),
    ));
    await _saveSettings();
    await beginEditExpression(id);
    return id;
  }

  Future<int> duplicateExpression(int id) async {
    final src = settings.expressionById(id);
    final newId = _nextExpressionId();
    settings.expressions.add(FaceExpression(
      id: newId,
      name: uniqueExpressionName('${src.name} (copy)', _namesExcept(null)),
      config: src.config.copy(),
    ));
    await _saveSettings();
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
    await _saveSettings();
    _notify();
  }

  /// Rename; names are unique (ignoring case). Returns an error, or null.
  Future<String?> renameExpression(int id, String name) async {
    name = name.trim();
    if (name.isEmpty) return 'Enter a name';
    final other = settings.expressionByName(name);
    if (other != null && other.id != id) return '"${other.name}" is already used';
    settings.expressionById(id).name = name;
    await _saveSettings();
    _notify();
    return null;
  }

  /// Add back the templates whose names are missing (with new ids if needed).
  Future<void> restoreTemplates() async {
    for (final t in FaceExpression.templates()) {
      if (settings.expressionByName(t.name) != null) continue;
      if (settings.expressions.any((e) => e.id == t.id)) t.id = _nextExpressionId();
      settings.expressions.add(t);
    }
    settings.expressions.sort((a, b) => a.id.compareTo(b.id));
    await _saveSettings();
    _notify();
  }

  int _nextExpressionId() {
    var maxId = 0;
    for (final e in settings.expressions) {
      if (e.id > maxId) maxId = e.id;
    }
    return maxId + 1;
  }

}
