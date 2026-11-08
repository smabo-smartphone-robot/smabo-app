import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// Connection lifecycle states for a single WebSocket endpoint.
enum WsStatus { disconnected, connecting, connected, error }

/// Says who we are as the first frame after the socket opens (smabo-brain's
/// pairing; see brain_pairing.dart).
abstract class WsAuthenticator {
  Map<String, dynamic> firstFrame();

  /// The peer's answer: true accepted, false refused, null not an answer.
  Future<bool?> handleReply(Map<String, dynamic> frame);
}

/// A single inbound message: a topic and its JSON payload.
class WireMessage {
  WireMessage(this.topic, this.msg);

  final String topic;
  final Map<String, dynamic> msg;
}

/// A plain auto-reconnecting WebSocket client that exchanges JSON frames.
///
/// The app uses **no ROS runtime and no ROS library** — this is just a
/// WebSocket connection. The JSON envelope it uses (`op`/`topic`/`msg`) and the
/// message bodies (built in `ros_messages.dart`) are intentionally shaped to be
/// **rosbridge v2.0 compatible**, so that a `rosbridge_suite` bridge can be
/// placed in front of an endpoint and everything interoperates. Whether the
/// peer actually speaks ROS is irrelevant to this client.
///
/// Auto-reconnects with a capped backoff while [isEnabled] is true.
///
/// With an [authenticator], the first frame says who we are and the status
/// turns "connected" only once the peer accepts it. A peer that does not
/// answer within [authReplyTimeout] (an old brain, smabo-brain-ros) is taken
/// as one that does not check; a refusal waits [refusedRetry] before the
/// next try (or until [retryNow]).
class WsClient {
  WsClient({required this.label, this.authenticator});

  /// Human-readable name for this endpoint (e.g. "ESP32", "Brain").
  final String label;

  WsAuthenticator? authenticator;

  static const authReplyTimeout = Duration(seconds: 2);
  static const refusedRetry = Duration(seconds: 15);
  Timer? _authTimer;
  bool _awaitingAuth = false;
  bool _refused = false;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;

  String? _url;
  bool _enabled = false;
  int _backoffMs = _minBackoffMs;

  static const int _minBackoffMs = 500;
  static const int _maxBackoffMs = 8000;

  WsStatus _status = WsStatus.disconnected;
  WsStatus get status => _status;
  bool get isConnected => _status == WsStatus.connected;
  bool get isEnabled => _enabled;
  String? get url => _url;

  final _statusController = StreamController<WsStatus>.broadcast();
  final _messageController = StreamController<WireMessage>.broadcast();
  final _noticeController = StreamController<String>.broadcast();

  /// Emits whenever the connection status changes.
  Stream<WsStatus> get statusStream => _statusController.stream;

  /// Emits every inbound publish message (topic + payload).
  Stream<WireMessage> get messages => _messageController.stream;

  /// Emits `notice`/`error` text from the peer (e.g. ESP32 reboot notice).
  Stream<String> get notices => _noticeController.stream;

  /// Begin connecting to [url] and keep the connection alive across drops.
  ///
  /// Safe to call repeatedly; if the URL is unchanged and already connecting
  /// or connected, it is a no-op.
  void connect(String url) {
    if (_enabled && _url == url && _status != WsStatus.disconnected) {
      return;
    }
    _url = url;
    _enabled = true;
    _backoffMs = _minBackoffMs;
    _open();
  }

  /// Stop the connection and disable auto-reconnect.
  Future<void> disconnect() async {
    _enabled = false;
    _awaitingAuth = false;
    _authTimer?.cancel();
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
    _setStatus(WsStatus.disconnected);
  }

  void _open() {
    if (_url == null) return;
    _setStatus(WsStatus.connecting);
    try {
      final channel = WebSocketChannel.connect(Uri.parse(_url!));
      _channel = channel;
      _sub = channel.stream.listen(
        _onData,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      // Only report "connected" once the socket is actually open (channel.ready
      // completes), so the status — and the connect/disconnect notifications
      // built on it — are reliable and don't flap when the server is down.
      channel.ready.then((_) {
        if (!_enabled || _channel != channel) return;
        final auth = authenticator;
        if (auth == null) return _opened();
        _awaitingAuth = true;
        _send(auth.firstFrame());
        _authTimer?.cancel();
        _authTimer = Timer(authReplyTimeout, () {
          if (_awaitingAuth && _channel == channel) _opened();
        });
      }).catchError((_) {
        if (_channel == channel) _scheduleReconnect();
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _opened() {
    _awaitingAuth = false;
    _authTimer?.cancel();
    _setStatus(WsStatus.connected);
    _backoffMs = _minBackoffMs;
  }

  /// Reconnect at once (e.g. after an invite code was entered).
  void retryNow() {
    if (!_enabled) return;
    _refused = false;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
    _backoffMs = _minBackoffMs;
    _open();
  }

  void _scheduleReconnect() {
    _awaitingAuth = false;
    _authTimer?.cancel();
    _setStatus(_enabled ? WsStatus.error : WsStatus.disconnected);
    _sub?.cancel();
    _sub = null;
    final old = _channel;
    _channel = null;
    if (_refused) {
      try {
        old?.sink.close(ws_status.normalClosure);
      } catch (_) {}
    }
    if (!_enabled) return;
    _reconnectTimer?.cancel();
    final delay = _refused ? refusedRetry : Duration(milliseconds: _backoffMs);
    _refused = false;
    _reconnectTimer = Timer(delay, () {
      if (_enabled) _open();
    });
    _backoffMs = (_backoffMs * 2).clamp(_minBackoffMs, _maxBackoffMs);
  }

  void _onAuthReply(Map<String, dynamic> frame) {
    // Decide now: the peer closes the socket right after a refusal.
    final accepted =
        frame['ok'] == true || frame['auth'] == false || frame['reason'] == 'no_auth';
    _awaitingAuth = false;
    _authTimer?.cancel();
    final channel = _channel;
    authenticator!.handleReply(frame).then((_) {
      if (accepted && channel != null && _channel == channel) _opened();
    });
    if (!accepted) {
      _refused = true;
      _scheduleReconnect();
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> frame;
    try {
      frame = json.decode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final op = frame['op'];
    if (_awaitingAuth && (op == 'auth' || op == 'pair')) {
      _onAuthReply(frame);
      return;
    }
    if (op == 'publish') {
      final topic = frame['topic'] as String?;
      final msg = frame['msg'];
      if (topic != null && msg is Map<String, dynamic>) {
        _messageController.add(WireMessage(topic, msg));
      }
    } else if (op == 'notice' || op == 'error') {
      final m = frame['message'];
      if (m is String) _noticeController.add('[$op] $m');
    } else if (op == 'set_config') {
      // get_config response — surface as a message on the synthetic topic so
      // the settings layer can pick it up.
      final cfg = frame['config'];
      if (cfg is Map<String, dynamic>) {
        _messageController.add(WireMessage('__config__', cfg));
      }
    }
  }

  /// Publish a message: `{"op":"publish","topic":...,"msg":...}`.
  void publish(String topic, Map<String, dynamic> msg) {
    _send({'op': 'publish', 'topic': topic, 'msg': msg});
  }

  /// Send a raw op frame (set_mode, set_config, get_config, subscribe…).
  void sendOp(Map<String, dynamic> frame) => _send(frame);

  /// Announce a topic this client publishes (rosbridge `advertise`).
  void advertise(String topic, String type) {
    _send({'op': 'advertise', 'topic': topic, 'type': type});
  }

  /// Ask to receive a topic (rosbridge `subscribe`).
  void subscribe(String topic, String type) {
    _send({'op': 'subscribe', 'topic': topic, 'type': type});
  }

  void _send(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(json.encode(frame));
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _setStatus(WsStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _authTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _statusController.close();
    _messageController.close();
    _noticeController.close();
  }
}
