import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/models/app_settings.dart';
import 'package:smabo/core/models/phone_config.dart';
import 'package:smabo/services/config_server.dart';

void main() {
  test('settings tree follows the shared schema (smabo-sim serves the same)', () {
    final j = phoneConfigToJson(AppSettings());
    expect(j.keys.toSet(), {'brain', 'http', 'sensors', 'voice', 'speech', 'face', 'app'});
    expect(j['http'], {'port': 8081});
    expect(j['sensors']['imu'], {'enabled': false, 'rate_hz': 20});
    expect(j['face']['expression'], 'Normal');
    expect(j['face']['expressions'], containsAllInOrder(['Normal', 'Sleepy', 'Angry']));
    expect(j['app']['schema'], 1);
  });

  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim(), appVersion);
  });

  test('patch keeps writable, well-typed values and lists the rest', () {
    final p = parsePhoneConfigPatch({
      'sensors': {'imu': {'rate_hz': 500.0, 'enabled': true}, 'gps': {'enabled': 'yes'}},
      'brain': {'host': 'x'},
      'face': {'expression': ' angry ', 'expressions': []},
      'voice': {'wake_word': '  ねえ '},
      'nope': 1,
    }, expressionNames: ['Normal', 'Angry']);
    expect(p.values, {
      'sensors.imu.rate_hz': 200,
      'sensors.imu.enabled': true,
      'voice.wake_word': 'ねえ',
      'face.expression': 'angry',
    });
    expect(p.ignored..sort(), ['brain.host', 'face.expressions', 'nope', 'sensors.gps.enabled']);
    for (final bad in [3, 'Sad', '']) {
      expect(parsePhoneConfigPatch({'face': {'expression': bad}}, expressionNames: ['Normal']).ignored,
          ['face.expression']);
    }
  });

  test('patch ignores an unknown or mistyped expression', () {
    final p = parsePhoneConfigPatch({'brain': {'host': 'x'}, 'face': {'expression': 3, 'expressions': []},
      'nope': 1, 'sensors': {'gps': {'enabled': 'yes'}}}, expressionNames: ['Normal']);
    expect(p.ignored..sort(),
        ['brain.host', 'face.expression', 'face.expressions', 'nope', 'sensors.gps.enabled']);
  });

  test('REST /config: GET, POST, CORS, errors', () async {
    final state = <String, dynamic>{'voice': {'wake_word': 'smabo'}};
    final server = ConfigServer(
      read: () => state,
      write: (patch) async {
        state['voice'] = patch['voice'];
        return ['app.name'];
      },
      port: 0,
    );
    expect(await server.start(), isTrue);
    final base = 'http://127.0.0.1:${server.boundPort}';
    final client = HttpClient();
    Future<(int, String, HttpHeaders)> call(String method, String path, [String? body]) async {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      if (body != null) req.add(utf8.encode(body));
      final res = await req.close();
      return (res.statusCode, await utf8.decoder.bind(res).join(), res.headers);
    }

    var (code, body, headers) = await call('GET', '/config');
    expect(code, 200);
    expect(headers.value('access-control-allow-origin'), '*');
    expect(jsonDecode(body)['voice']['wake_word'], 'smabo');
    (code, body, _) = await call('POST', '/config', '{"voice": {"wake_word": "ねえ"}}');
    expect(jsonDecode(body), {'ok': true, 'ignored': ['app.name']});
    expect(state['voice'], {'wake_word': 'ねえ'});
    (code, _, _) = await call('POST', '/config', '{');
    expect(code, 400);
    (code, _, _) = await call('OPTIONS', '/config');
    expect(code, 204);
    (code, _, _) = await call('GET', '/mode');
    expect(code, 404);
    client.close();
    await server.stop();
  });

  test('REST /face: schema, list, patch, add, delete', () async {
    final items = <int, Map<String, dynamic>>{1: {'id': 1, 'name': 'Normal'}};
    final server = ConfigServer(read: () => {}, write: (_) async => [], face: _Face(items), port: 0);
    expect(await server.start(), isTrue);
    final client = HttpClient();
    Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return (res.statusCode, jsonDecode(await utf8.decoder.bind(res).join()));
    }

    expect((await call('GET', '/face/schema')).$2, {'schema': 1});
    expect((await call('GET', '/face/expressions')).$2['expressions'], hasLength(1));
    expect((await call('POST', '/face/expressions/1', {'name': 'N'})).$2, {'ok': true, 'ignored': []});
    expect((await call('POST', '/face/expressions/7', {'name': 'N'})).$1, 404);
    expect((await call('POST', '/face/expressions', {'copy_of': 1})).$2, {'ok': true, 'id': 2});
    expect(items[2]!['name'], 'N (copy)');
    final png = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.boundPort}/face/preview.png?id=1&w=5000&h=3'))).close();
    expect(png.statusCode, 200);
    expect(png.headers.contentType?.mimeType, 'image/png');
    expect(await png.expand((b) => b).toList(), [0x89, 0x50, 0x4E, 0x47, 128, 16]);
    expect((await call('GET', '/face/preview.png?id=99')).$1, 404);
    expect((await call('DELETE', '/face/expressions/2')).$2, {'ok': true});
    expect((await call('DELETE', '/face/expressions/1')).$1, 400);
    client.close();
    await server.stop();
  });
}

class _Face implements FaceApi {
  _Face(this.items);
  final Map<int, Map<String, dynamic>> items;
  @override
  Map<String, dynamic> schema() => {'schema': 1};
  @override
  Map<String, dynamic> list() => {'active': 1, 'expressions': items.values.toList()};
  @override
  Future<List<String>?> patch(int id, Map<String, dynamic> patch) async {
    if (!items.containsKey(id)) return null;
    items[id]!.addAll(patch);
    return [];
  }

  @override
  Future<int?> add({int? copyOf, Map<String, dynamic> patch = const {}}) async {
    final id = items.keys.reduce((a, b) => a > b ? a : b) + 1;
    items[id] = {'id': id, 'name': '${items[copyOf]!['name']} (copy)'};
    return id;
  }

  @override
  Future<String?> delete(int id) async {
    if (items.length <= 1) return 'last';
    items.remove(id);
    return null;
  }

  @override
  Future<List<int>?> preview(int id, int width, int height) async =>
      items.containsKey(id) ? [0x89, 0x50, 0x4E, 0x47, width ~/ 8, height] : null;
}
