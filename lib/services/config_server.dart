import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/models/phone_config.dart';

/// The face expressions behind `/face/...` (see core/models/face_schema.dart).
abstract class FaceApi {
  Map<String, dynamic> schema();

  /// `{"active": id, "expressions": [...]}`
  Map<String, dynamic> list();

  /// Patch one expression. Returns the ignored paths, or null if [id] is unknown.
  Future<List<String>?> patch(int id, Map<String, dynamic> patch);

  /// Add one (a copy of [copyOf] when given). Returns its id, or null if [copyOf] is unknown.
  Future<int?> add({int? copyOf, Map<String, dynamic> patch = const {}});

  /// Delete one. Returns an error message, or null when deleted.
  Future<String?> delete(int id);

  /// Expression [id] drawn as a PNG of [width]×[height], or null if [id] is unknown.
  Future<List<int>?> preview(int id, int width, int height);
}

/// The phone's REST settings API, like the ESP32's: `GET /config` returns the
/// settings tree, `POST /config` applies a partial one and answers
/// `{"ok": true, "ignored": [...]}`. CORS is open so smabo-web (served from
/// anywhere on the LAN) can call it straight from the browser.
///
/// Face expressions, when [face] is given:
///
/// ```
///   GET    /face/schema            the editable fields (smabo-web builds its editor from it)
///   GET    /face/expressions       {"active": id, "expressions": [...]}
///   POST   /face/expressions/<id>  a partial expression → {"ok": true, "ignored": [...]}
///   POST   /face/expressions       {"copy_of"?: id, ...fields} → {"ok": true, "id": new id}
///   DELETE /face/expressions/<id>  → {"ok": true}
///   GET    /face/preview.png?id=<id>&w=<px>&h=<px>   the expression as drawn on the phone
/// ```
class ConfigServer {
  /// The largest preview side served, in pixels.
  static const previewMaxSide = 1024;

  ConfigServer({required this.read, required this.write, this.face, this.port = phoneConfigPort});

  final Map<String, dynamic> Function() read;
  final Future<List<String>> Function(Map<String, dynamic> patch) write;
  final FaceApi? face;
  final int port;

  HttpServer? _server;

  /// The port actually listened on (useful when [port] is 0), or null.
  int? get boundPort => _server?.port;

  Future<bool> start() async {
    if (_server != null) return true;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    } on SocketException {
      return false;
    }
    _server!.listen(_handle, onError: (_) {});
    return true;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..set('Access-Control-Allow-Private-Network', 'true');
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
      } else if (req.uri.path == '/config' && req.method == 'GET') {
        _json(res, read());
      } else if (req.uri.path == '/config' && req.method == 'POST') {
        final body = await _body(req);
        body == null ? _badJson(res) : _json(res, {'ok': true, 'ignored': await write(body)});
      } else if (face != null && req.uri.pathSegments.firstOrNull == 'face') {
        await _face(req, res, face!);
      } else {
        _json(res, {'error': 'not found'}, status: HttpStatus.notFound);
      }
    } catch (e) {
      _json(res, {'error': '$e'}, status: HttpStatus.internalServerError);
    }
    await res.close();
  }

  Future<void> _face(HttpRequest req, HttpResponse res, FaceApi face) async {
    final seg = req.uri.pathSegments.where((p) => p.isNotEmpty).toList();
    final id = seg.length == 3 && seg[1] == 'expressions' ? int.tryParse(seg[2]) : null;
    final m = req.method;
    if (seg.length == 2 && seg[1] == 'schema' && m == 'GET') {
      _json(res, face.schema());
    } else if (seg.length == 2 && seg[1] == 'expressions' && m == 'GET') {
      _json(res, face.list());
    } else if (seg.length == 2 && seg[1] == 'expressions' && m == 'POST') {
      final body = await _body(req);
      if (body == null) return _badJson(res);
      final copyOf = body.remove('copy_of');
      final newId = await face.add(copyOf: copyOf is num ? copyOf.toInt() : null, patch: body);
      newId == null
          ? _json(res, {'error': 'no such expression'}, status: HttpStatus.notFound)
          : _json(res, {'ok': true, 'id': newId});
    } else if (id != null && m == 'POST') {
      final body = await _body(req);
      if (body == null) return _badJson(res);
      final ignored = await face.patch(id, body);
      ignored == null
          ? _json(res, {'error': 'no such expression'}, status: HttpStatus.notFound)
          : _json(res, {'ok': true, 'ignored': ignored});
    } else if (seg.length == 2 && seg[1] == 'preview.png' && m == 'GET') {
      final q = req.uri.queryParameters;
      final pid = int.tryParse(q['id'] ?? '');
      int dim(String k, int d) => (int.tryParse(q[k] ?? '') ?? d).clamp(16, previewMaxSide);
      final png = pid == null ? null : await face.preview(pid, dim('w', 400), dim('h', 200));
      if (png == null) {
        return _json(res, {'error': 'no such expression'}, status: HttpStatus.notFound);
      }
      res.headers
        ..contentType = ContentType('image', 'png')
        ..set('Cache-Control', 'no-store');
      res.add(png);
    } else if (id != null && m == 'DELETE') {
      final err = await face.delete(id);
      err == null
          ? _json(res, {'ok': true})
          : _json(res, {'error': err}, status: HttpStatus.badRequest);
    } else {
      _json(res, {'error': 'not found'}, status: HttpStatus.notFound);
    }
  }

  Future<Map<String, dynamic>?> _body(HttpRequest req) async {
    try {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      return body is Map ? body.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  void _badJson(HttpResponse res) => _json(res, {'error': 'bad json'}, status: HttpStatus.badRequest);

  void _json(HttpResponse res, Object body, {int status = HttpStatus.ok}) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }
}
