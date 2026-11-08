import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smabo/core/wire/brain_pairing.dart';
import 'package:smabo/core/wire/ws_client.dart';
import 'package:smabo/services/config_server.dart';

void main() {
  group('BrainPairing', () {
    test('first frame: pair with an invite, else auth (empty token when unpaired)', () {
      final p = BrainPairing();
      expect(p.firstFrame(), {'op': 'auth', 'token': ''});
      p.setInvite(' abcd-efgh ');
      expect(p.firstFrame(),
          {'op': 'pair', 'code': 'abcd-efgh', 'role': 'app', 'name': 'smabo-app'});
    });

    test('a pair reply stores the token and only the hash of the relay key', () async {
      var saves = 0;
      final p = BrainPairing(onSave: (_) async => saves++)..setInvite('ABCD-EFGH');
      final ok = await p.handleReply(
          {'op': 'pair', 'ok': true, 'token': 'tok', 'relay_key': 'key', 'name': 'phone'});
      expect(ok, isTrue);
      expect(p.token, 'tok');
      expect(p.relayKeySha256, BrainPairing.sha256Hex('key'));
      expect(p.relayKeySha256, isNot(contains('key')));
      expect(p.invite, isEmpty);
      expect(saves, 1);
      expect(p.firstFrame(), {'op': 'auth', 'token': 'tok'});
    });

    test('a refused invite is dropped (one try per code)', () async {
      final p = BrainPairing()..setInvite('WRONG');
      expect(await p.handleReply({'op': 'pair', 'ok': false, 'reason': 'wrong_code'}), isFalse);
      expect(p.invite, isEmpty);
      expect(p.paired, isFalse);
      expect(p.refused, 'wrong_code');
    });

    test('"unauthorized" for a known token forgets the pairing', () async {
      final p = BrainPairing(token: 't', relayKeySha256: BrainPairing.sha256Hex('k'));
      expect(await p.handleReply({'op': 'auth', 'ok': false, 'reason': 'unauthorized'}), isFalse);
      expect(p.paired, isFalse);
      expect(p.locked, isFalse);
    });

    test('a --no-auth brain is accepted and the token kept', () async {
      final p = BrainPairing(token: 't');
      expect(await p.handleReply({'op': 'auth', 'ok': true, 'auth': false, 'reason': 'no_auth'}),
          isTrue);
      expect(p.token, 't');
      expect(p.brainChecksTokens, isFalse);
    });

    test('other frames are not answers', () async {
      expect(await BrainPairing().handleReply({'op': 'publish'}), isNull);
    });

    test('relay key check', () {
      expect(BrainPairing().relayAllowed(null), isTrue); // unpaired: open
      final p = BrainPairing(token: 't', relayKeySha256: BrainPairing.sha256Hex('k'));
      expect(p.relayAllowed('k'), isTrue);
      expect(p.relayAllowed('x'), isFalse);
      expect(p.relayAllowed(''), isFalse);
      expect(p.relayAllowed(null), isFalse);
    });

    test('takeInvite pulls brain.invite out of a REST patch', () {
      final patch = <String, dynamic>{
        'brain': {'invite': ' ABCD-EFGH '},
        'voice': {'enabled': true},
      };
      expect(takeInvite(patch), 'ABCD-EFGH');
      expect(patch, {'voice': {'enabled': true}});
      final other = <String, dynamic>{
        'brain': {'invite': '', 'host': 'x'}
      };
      expect(takeInvite(other), isNull);
      expect(other, {'brain': {'host': 'x'}});
      expect(takeInvite({'voice': {}}), isNull);
    });
  });

  group('ConfigServer lock', () {
    late ConfigServer server;
    late BrainPairing pairing;
    final client = HttpClient();

    setUp(() async {
      pairing = BrainPairing();
      server = ConfigServer(
        read: () => {'ok': 1},
        write: (_) async => [],
        port: 0,
        locked: () => pairing.locked,
        relayAllowed: pairing.relayAllowed,
      );
      expect(await server.start(), isTrue);
    });
    tearDown(() => server.stop());

    Future<HttpClientResponse> get({String? key}) async {
      final req = await client.get('127.0.0.1', server.boundPort!, '/config');
      if (key != null) req.headers.set(ConfigServer.relayKeyHeader, key);
      final res = await req.close();
      await res.drain<void>();
      return res;
    }

    test('unpaired: open, with CORS', () async {
      final res = await get();
      expect(res.statusCode, 200);
      expect(res.headers.value('access-control-allow-origin'), '*');
    });

    test('paired: only with the relay key, and no CORS', () async {
      pairing
        ..token = 't'
        ..relayKeySha256 = BrainPairing.sha256Hex('k');
      final denied = await get();
      expect(denied.statusCode, 401);
      expect(denied.headers.value('access-control-allow-origin'), isNull);
      expect((await get(key: 'wrong')).statusCode, 401);
      final ok = await get(key: 'k');
      expect(ok.statusCode, 200);
      expect(ok.headers.value('access-control-allow-origin'), isNull);
    });
  });

  group('WsClient with an authenticator', () {
    late HttpServer server;
    late List<Map<String, dynamic>> received;
    // How the fake brain answers the first frame (null: say nothing).
    Map<String, dynamic>? Function(Map<String, dynamic>)? answer;
    var closeAfterAnswer = false;

    setUp(() async {
      received = [];
      closeAfterAnswer = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((data) {
          final f = jsonDecode(data as String) as Map<String, dynamic>;
          received.add(f);
          if (received.length == 1) {
            final a = answer?.call(f);
            if (a != null) ws.add(jsonEncode(a));
            if (closeAfterAnswer) ws.close(4001);
          }
        });
      });
    });
    tearDown(() => server.close(force: true));

    Future<WsStatus> statusAfter(WsClient c, Duration d) async {
      await Future<void>.delayed(d);
      return c.status;
    }

    test('connected only after the brain accepts the token', () async {
      final p = BrainPairing(token: 'tok');
      answer = (f) => {'op': 'auth', 'ok': true, 'role': 'app', 'name': 'phone', 'id': 'x'};
      final c = WsClient(label: 'Brain', authenticator: p);
      final statuses = <WsStatus>[];
      c.statusStream.listen(statuses.add);
      c.connect('ws://127.0.0.1:${server.port}');
      expect(await statusAfter(c, const Duration(milliseconds: 300)), WsStatus.connected);
      expect(received.first, {'op': 'auth', 'token': 'tok'});
      expect(statuses, [WsStatus.connecting, WsStatus.connected]);
      await c.disconnect();
      c.dispose();
    });

    test('pairing with an invite stores the token', () async {
      final p = BrainPairing()..setInvite('ABCD-EFGH');
      answer = (f) => {'op': 'pair', 'ok': true, 'token': 'new', 'relay_key': 'rk', 'name': 'phone'};
      final c = WsClient(label: 'Brain', authenticator: p);
      c.connect('ws://127.0.0.1:${server.port}');
      expect(await statusAfter(c, const Duration(milliseconds: 300)), WsStatus.connected);
      expect(received.first['op'], 'pair');
      expect(p.token, 'new');
      expect(p.locked, isTrue);
      await c.disconnect();
      c.dispose();
    });

    test('a refusal is an error and the next try waits', () async {
      final p = BrainPairing(token: 'old');
      answer = (f) => {'op': 'auth', 'ok': false, 'reason': 'unauthorized'};
      closeAfterAnswer = true;
      final c = WsClient(label: 'Brain', authenticator: p);
      c.connect('ws://127.0.0.1:${server.port}');
      expect(await statusAfter(c, const Duration(milliseconds: 1500)), WsStatus.error);
      expect(received, hasLength(1)); // no quick retry
      expect(p.paired, isFalse); // the brain no longer knows it
      await c.disconnect();
      c.dispose();
    });

    test('a brain that does not answer (old brain, brain-ros) is used as before', () async {
      answer = null;
      final c = WsClient(label: 'Brain', authenticator: BrainPairing());
      c.connect('ws://127.0.0.1:${server.port}');
      expect(await statusAfter(c, const Duration(milliseconds: 500)), WsStatus.connecting);
      expect(await statusAfter(c, WsClient.authReplyTimeout), WsStatus.connected);
      await c.disconnect();
      c.dispose();
    });
  });
}
