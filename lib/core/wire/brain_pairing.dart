import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ws_client.dart';

/// Pairing with smabo-brain, as smabo-esp32 and smabo-sim do it.
///
/// A paired phone shows its token as the first frame on every connection
/// (`{"op": "auth", "token": ...}`). To pair, it shows a one-time invite code
/// from smabo-web instead (`{"op": "pair", "code": ...}`) and the brain answers
/// with a token and a relay key. The phone keeps the token and only the SHA-256
/// of the relay key; from then on its REST settings API answers only requests
/// that carry the key in `X-Smabo-Relay-Key` (the brain adds it when it relays
/// smabo-web's settings) and sends no CORS headers.
///
/// The invite comes from Settings → Brain → "Pair", or as
/// `{"brain": {"invite": "ABCD-EFGH"}}` posted to the REST `/config` while the
/// phone is not paired. When the brain says it no longer knows the token (the
/// phone was removed in smabo-web, or the brain was reset), the phone forgets
/// it and takes invites again.
class BrainPairing implements WsAuthenticator {
  BrainPairing({this.token = '', this.relayKeySha256 = '', this.name = 'smabo-app', this.onSave});

  static const relayKeyHeader = 'x-smabo-relay-key';
  static const role = 'app';
  static const _kToken = 'smabo.brainToken';
  static const _kRelay = 'smabo.relayKeySha256';

  String token;
  String relayKeySha256;
  String name;

  /// A code waiting to be shown on the next connection (kept in memory only).
  String invite = '';

  /// The last reason the brain gave for refusing us ('' when accepted).
  String refused = '';

  /// False when the brain runs with `--no-auth` (or is an old one).
  bool brainChecksTokens = true;

  final Future<void> Function(BrainPairing)? onSave;

  bool get paired => token.isNotEmpty;

  /// Paired with a relay key: REST only for the brain, no CORS.
  bool get locked => relayKeySha256.isNotEmpty;

  static Future<BrainPairing> load() async {
    final p = await SharedPreferences.getInstance();
    return BrainPairing(
      token: p.getString(_kToken) ?? '',
      relayKeySha256: p.getString(_kRelay) ?? '',
      onSave: (b) async {
        await p.setString(_kToken, b.token);
        await p.setString(_kRelay, b.relayKeySha256);
      },
    );
  }

  static String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

  void setInvite(String code) => invite = code.trim();

  /// What to send right after connecting. An unpaired phone without an invite
  /// sends an empty token, so a brain that checks tokens answers at once.
  @override
  Map<String, dynamic> firstFrame() {
    if (invite.isNotEmpty) {
      return {'op': 'pair', 'code': invite, 'role': role, 'name': name};
    }
    return {'op': 'auth', 'token': token};
  }

  /// The brain's answer to [firstFrame]: true accepted, false refused, null
  /// when [frame] is not an answer.
  @override
  Future<bool?> handleReply(Map<String, dynamic> frame) async {
    final op = frame['op'];
    if (op != 'auth' && op != 'pair') return null;
    final reason = '${frame['reason'] ?? ''}';
    if (frame['auth'] == false || reason == 'no_auth') {
      // The brain does not check tokens: keep ours for when it does.
      invite = '';
      refused = '';
      brainChecksTokens = false;
      return true;
    }
    brainChecksTokens = true;
    final ok = frame['ok'] == true;
    if (op == 'pair') {
      invite = ''; // one try per code
      final newToken = frame['token'];
      if (ok && newToken is String && newToken.isNotEmpty) {
        token = newToken;
        final key = frame['relay_key'];
        relayKeySha256 = key is String && key.isNotEmpty ? sha256Hex(key) : '';
        await onSave?.call(this);
      }
    } else if (!ok && paired && reason == 'unauthorized') {
      // Removed from the brain (or the brain was reset): forget the pairing
      // so the REST API takes a new invite again.
      token = '';
      relayKeySha256 = '';
      await onSave?.call(this);
    }
    refused = ok ? '' : (reason.isEmpty ? 'refused' : reason);
    return ok;
  }

  /// Forget the pairing (Settings → Brain → "Unpair").
  Future<void> forget() async {
    token = '';
    relayKeySha256 = '';
    invite = '';
    await onSave?.call(this);
  }

  /// Whether a REST request may proceed: anything while unlocked, else only
  /// the brain's relay key.
  bool relayAllowed(String? key) {
    if (!locked) return true;
    if (key == null || key.isEmpty) return false;
    final got = sha256Hex(key);
    if (got.length != relayKeySha256.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got.codeUnitAt(i) ^ relayKeySha256.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// A human-readable line for the settings screen.
  String describe() {
    if (!brainChecksTokens) return 'The brain does not ask for pairing (--no-auth)';
    if (refused == 'unauthorized' && !paired) {
      return 'Not paired. Get an invite code in smabo-web → Devices → Add phone';
    }
    if (refused.isNotEmpty) return 'The brain refused: $refused';
    return paired ? 'Paired' : 'Not paired';
  }

  /// For `GET /config` (never the token).
  Map<String, dynamic> status() => {'paired': paired};
}

/// Remove `brain.invite` from a REST config patch and return it (or null).
String? takeInvite(Map<String, dynamic> patch) {
  final brain = patch['brain'];
  if (brain is! Map || !brain.containsKey('invite')) return null;
  final rest = Map<String, dynamic>.from(brain)..remove('invite');
  if (rest.isEmpty) {
    patch.remove('brain');
  } else {
    patch['brain'] = rest;
  }
  final code = brain['invite'];
  return code is String && code.trim().isNotEmpty ? code.trim() : null;
}
