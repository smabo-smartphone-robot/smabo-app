import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/models/phone_config.dart' show appVersion;
import 'package:smabo/core/wire/ros_compat.dart';

void main() {
  test('hello carries the protocol number and the app version', () {
    final hello = jsonDecode(RosProtocol.helloMsg()['data'] as String) as Map;
    expect(hello['protocol'], RosProtocol.version);
    expect(hello['client'], 'smabo-app');
    expect(hello['version'], appVersion);
  });

  test('brain info warns only when the protocol differs', () {
    Map<String, dynamic> info(Object protocol) => {
          'data': jsonEncode({'protocol': protocol, 'brain': 'smabo-brain', 'version': '0.1.0'})
        };
    expect(RosProtocol.brainInfoWarning(info(RosProtocol.version)), isNull);
    expect(RosProtocol.brainInfoWarning(info(RosProtocol.version + 1)), contains('protocol'));
    expect(RosProtocol.brainInfoWarning({'data': 'not json'}), isNull);
    expect(RosProtocol.brainInfoWarning(const {}), isNull);
  });
}
