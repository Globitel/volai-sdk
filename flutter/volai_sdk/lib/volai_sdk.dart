// volai_sdk - thin Dart layer over the native Volai libraries (ios/VolaiSDK,
// android volai-sdk). The protocol, audio and reconnect logic live in the
// native code; this file exposes the same shape as the other SDKs:
// VolaiClient, chat sessions and voice calls.
import 'dart:async';

import 'package:flutter/services.dart';

const int sdkContractVersion = 1;

const MethodChannel _methods = MethodChannel('com.globitel.volai/sdk');
const EventChannel _events = EventChannel('com.globitel.volai/events');
Stream<Map<String, dynamic>>? _eventStream;

/// One broadcast stream of native events, shared by every session and call.
Stream<Map<String, dynamic>> _nativeEvents() {
  return _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => _toMap(e))
      .asBroadcastStream();
}

Map<String, dynamic> _toMap(Object? value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), _convert(v)));
  }
  return <String, dynamic>{};
}

Object? _convert(Object? value) {
  if (value is Map) return _toMap(value);
  if (value is List) return value.map(_convert).toList();
  return value;
}

/// Thrown for API errors (non-2xx) and native failures.
class VolaiException implements Exception {
  VolaiException(this.code, this.message, {this.status, this.reason});
  final String code;
  final String message;
  final int? status;
  final String? reason;

  @override
  String toString() => 'VolaiException($code${status != null ? ' $status' : ''}): $message';
}

VolaiException _wrap(PlatformException e) {
  final details = e.details;
  int? status;
  String? reason;
  if (details is Map) {
    status = (details['status'] as num?)?.toInt();
    reason = details['reason'] as String?;
  }
  return VolaiException(e.code, e.message ?? e.code, status: status, reason: reason);
}

Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
  try {
    return await _methods.invokeMethod<T>(method, args) as T;
  } on PlatformException catch (e) {
    throw _wrap(e);
  }
}

class SessionRequest {
  SessionRequest({
    required this.agentId,
    this.deviceId,
    this.callerName,
    this.callerPhone,
    this.callerEmail,
    this.context,
    this.verificationTokens,
    this.sessionGrant,
    this.publicLinkPassword,
  });

  final String agentId;
  final String? deviceId;
  final String? callerName;
  final String? callerPhone;
  final String? callerEmail;
  final Map<String, Object?>? context;
  /// `{'phone': token}` or `{'phone': [tokens]}`, likewise `email`.
  final Map<String, Object?>? verificationTokens;
  /// Session grant minted by your backend with the secret key.
  final String? sessionGrant;
  final String? publicLinkPassword;

  Map<String, Object?> toMap() => {
        'agentId': agentId,
        'deviceId': deviceId,
        'callerName': callerName,
        'callerPhone': callerPhone,
        'callerEmail': callerEmail,
        'context': context,
        'verificationTokens': verificationTokens,
        'sessionGrant': sessionGrant,
        'publicLinkPassword': publicLinkPassword,
      };
}

class PublicAgent {
  PublicAgent(this.raw);
  final Map<String, dynamic> raw;
  String get apiId => raw['api_id'] as String? ?? '';
  String get name => raw['name'] as String? ?? '';
  String? get agentArchitecture => raw['agentArchitecture'] as String?;
  List<String> get voiceTransports =>
      (raw['voiceTransports'] as List?)?.map((e) => e.toString()).toList() ?? const [];
  String get defaultVoiceTransport => raw['defaultVoiceTransport'] as String? ?? 'webrtc';
}

class ChatSessionInfo {
  ChatSessionInfo(Map<String, dynamic> m)
      : sessionId = m['sessionId'] as String,
        chatToken = m['chatToken'] as String,
        eventsUrl = m['eventsUrl'] as String,
        initialGreeting = m['initialGreeting'] is Map ? _toMap(m['initialGreeting']) : null;
  final String sessionId;
  final String chatToken;
  final String eventsUrl;
  /// `{'id': ..., 'content': ...}` when the agent greets first.
  final Map<String, dynamic>? initialGreeting;
}

class VoiceCallInfo {
  VoiceCallInfo(Map<String, dynamic> m)
      : callId = m['callId'] as String,
        sessionId = m['sessionId'] as String,
        transport = m['transport'] as String,
        wsUrl = m['wsUrl'] as String,
        wsTokenExpiresIn = (m['wsTokenExpiresIn'] as num).toInt();
  final String callId;
  final String sessionId;
  final String transport;
  final String wsUrl;
  final int wsTokenExpiresIn;
}

class SessionReady {
  SessionReady(this.raw);
  final Map<String, dynamic> raw;
  String get sessionId => raw['session_id'] as String;
  int get epoch => (raw['epoch'] as num).toInt();
  String get resumeToken => raw['resume_token'] as String;
  int get graceMs => (raw['grace_ms'] as num).toInt();
  bool get resumed => raw['resumed'] == true;
  int get uplinkRate => ((raw['uplink'] as Map?)?['rate'] as num?)?.toInt() ?? 16000;
  int get downlinkRate => ((raw['downlink'] as Map?)?['rate'] as num?)?.toInt() ?? 24000;
}

enum VoiceMode { fullDuplex, halfDuplex }

enum VoiceState { idle, connecting, connected, reconnecting, ended }

VoiceState _voiceState(String? s) =>
    VoiceState.values.firstWhere((v) => v.name == s, orElse: () => VoiceState.idle);

/// One native voice event. `type` is one of: ready, state, transcript,
/// agentSpeaking, interrupted, system, message, error, ended.
class VoiceEvent {
  VoiceEvent(this.raw);
  final Map<String, dynamic> raw;
  String get type => raw['type'] as String? ?? '';
  SessionReady? get ready => type == 'ready' ? SessionReady(_toMap(raw['ready'])) : null;
  VoiceState? get state => type == 'state' ? _voiceState(raw['state'] as String?) : null;
  String? get side => raw['side'] as String?;
  String? get text => raw['text'] as String?;
  bool get speaking => raw['speaking'] == true;
  int? get epoch => (raw['epoch'] as num?)?.toInt();
  String? get reason => raw['reason'] as String?;
  String? get content => raw['content'] as String?;
  String? get code => raw['code'] as String?;
  String? get message => raw['message'] as String?;
  bool get fatal => raw['fatal'] == true;

  @override
  String toString() => 'VoiceEvent($raw)';
}

class VolaiChatSession {
  VolaiChatSession(this.info);
  final ChatSessionInfo info;
  final StreamController<Map<String, dynamic>> _controller = StreamController.broadcast();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool closed = false;

  /// Chat events as delivered by the server (`type`: chat, chunk, chat_complete,
  /// typing, SESSION_ENDED, ...).
  Stream<Map<String, dynamic>> get events => _controller.stream;

  /// Opens the event stream. Idempotent.
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _nativeEvents().listen((payload) {
      if (payload['kind'] != 'chat' || payload['sessionId'] != info.sessionId) return;
      final event = _toMap(payload['event']);
      if (!_controller.isClosed) _controller.add(event);
      if (event['type'] == 'SESSION_ENDED') closed = true;
    });
    await _call<void>('startChat', {'sessionId': info.sessionId});
  }

  /// Sends a message; returns its id.
  Future<String> send(String content, {String? messageId}) =>
      _call<String>('sendChatMessage', {'sessionId': info.sessionId, 'content': content, 'messageId': messageId});

  Future<void> acknowledge(String messageId, String status) =>
      _call<void>('ackChatMessage', {'sessionId': info.sessionId, 'messageId': messageId, 'status': status});

  Future<void> typing() => _call<void>('chatTyping', {'sessionId': info.sessionId});

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _call<void>('closeChat', {'sessionId': info.sessionId});
    } catch (_) {}
    await _controller.close();
  }
}

class VolaiVoiceCall {
  VolaiVoiceCall(this.info) {
    _subscription = _nativeEvents().listen((payload) {
      if (payload['kind'] != 'voice' || payload['callId'] != info.callId) return;
      final event = VoiceEvent(payload);
      if (event.type == 'state') state = event.state ?? state;
      if (event.type == 'ready') ready = event.ready;
      if (!_controller.isClosed) _controller.add(event);
      if (event.type == 'ended') {
        state = VoiceState.ended;
        _subscription?.cancel();
        _subscription = null;
        _controller.close();
      }
    });
  }

  final VoiceCallInfo info;
  VoiceState state = VoiceState.idle;
  SessionReady? ready;
  final StreamController<VoiceEvent> _controller = StreamController.broadcast();
  StreamSubscription<Map<String, dynamic>>? _subscription;

  Stream<VoiceEvent> get events => _controller.stream;

  /// Opens the call; completes with `session.ready`. Request microphone
  /// permission first (the native engine starts capturing on connect).
  Future<SessionReady> connect() async {
    final raw = await _call<Map<Object?, Object?>>('connectVoice', {'callId': info.callId});
    ready = SessionReady(_toMap(raw));
    return ready!;
  }

  Future<void> setMuted(bool muted) => _call<void>('setVoiceMuted', {'callId': info.callId, 'muted': muted});

  /// Silences local playback without stopping the stream.
  Future<void> setPlaybackMuted(bool muted) =>
      _call<void>('setVoicePlaybackMuted', {'callId': info.callId, 'muted': muted});

  Future<void> end({String reason = 'user_hangup'}) =>
      _call<void>('endVoice', {'callId': info.callId, 'reason': reason});

  /// Development only: rewrite the socket origin (e.g. a dev stack's separate WebSocket port).
  Future<void> setSocketUrlOverride(String? url) =>
      _call<void>('setSocketUrlOverride', {'callId': info.callId, 'url': url});
}

class VolaiClient {
  VolaiClient({required String baseUrl, required String appKey})
      : _configured = _call<void>('configure', {'baseUrl': baseUrl, 'appKey': appKey});

  final Future<void> _configured;

  Future<PublicAgent> getAgent(String agentId) async {
    await _configured;
    return PublicAgent(_toMap(await _call<Map<Object?, Object?>>('getAgent', {'agentId': agentId})));
  }

  Future<VolaiChatSession> createChat(SessionRequest request) async {
    await _configured;
    return VolaiChatSession(ChatSessionInfo(_toMap(await _call<Map<Object?, Object?>>('createChat', {'request': request.toMap()}))));
  }

  Future<VolaiVoiceCall> createVoice(SessionRequest request, {VoiceMode mode = VoiceMode.fullDuplex}) async {
    await _configured;
    final raw = await _call<Map<Object?, Object?>>('createVoice', {
      'request': request.toMap(),
      'mode': mode == VoiceMode.halfDuplex ? 'half_duplex' : 'full_duplex',
    });
    return VolaiVoiceCall(VoiceCallInfo(_toMap(raw)));
  }
}
