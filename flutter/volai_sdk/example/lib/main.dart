import 'dart:io';

import 'package:flutter/material.dart';
import 'package:volai_sdk/volai_sdk.dart';

// Fill these in for your environment. On a development stack use the host
// machine's address (10.0.2.2 on the Android emulator) and a wsBase on the
// dev WebSocket port.
const String baseUrl = 'https://gicc.globitel.com';
const String appKey = '';
const String agentId = '';
const String? wsBase = null;

void main() => runApp(const VolaiExampleApp());

class VolaiExampleApp extends StatelessWidget {
  const VolaiExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: VolaiExamplePage());
}

class VolaiExamplePage extends StatefulWidget {
  const VolaiExamplePage({super.key});

  @override
  State<VolaiExamplePage> createState() => _VolaiExamplePageState();
}

class _VolaiExamplePageState extends State<VolaiExamplePage> {
  VolaiClient? _client;
  VolaiChatSession? _chat;
  VolaiVoiceCall? _call;
  final List<String> _log = [];
  final TextEditingController _message = TextEditingController(text: 'Hello');
  String _agentName = '';

  void _append(String line) => setState(() => _log.add(line));

  @override
  void initState() {
    super.initState();
    if (appKey.isEmpty) {
      _log.add('Set appKey and agentId in lib/main.dart');
      return;
    }
    _client = VolaiClient(baseUrl: baseUrl, appKey: appKey);
    _client!.getAgent(agentId).then((a) => setState(() => _agentName = '${a.name} (${a.defaultVoiceTransport})')).catchError((e) => _append('agent: $e'));
  }

  Future<void> _startChat() async {
    try {
      final chat = await _client!.createChat(SessionRequest(agentId: agentId, deviceId: 'flutter-example-${Platform.operatingSystem}'));
      chat.events.listen((e) {
        if (e['type'] == 'chat' || e['type'] == 'chunk') _append('agent: ${e['content'] ?? ''}');
      });
      await chat.start();
      _chat = chat;
      _append('chat started');
    } catch (e) {
      _append('chat: $e');
    }
  }

  Future<void> _sendChat() async {
    try {
      await _chat?.send(_message.text);
      _append('you: ${_message.text}');
    } catch (e) {
      _append('send: $e');
    }
  }

  Future<void> _startCall() async {
    try {
      final call = await _client!.createVoice(SessionRequest(agentId: agentId, deviceId: 'flutter-example-${Platform.operatingSystem}'));
      if (wsBase != null) {
        await call.setSocketUrlOverride(call.info.wsUrl.replaceFirst(RegExp(r'^wss?://[^/]+'), wsBase!));
      }
      call.events.listen((e) {
        if (e.type == 'transcript') {
          _append('${e.side}: ${e.text}');
        } else if (e.type == 'state' || e.type == 'ended' || e.type == 'error' || e.type == 'interrupted') {
          _append(e.toString());
        }
      });
      final ready = await call.connect();
      _call = call;
      _append('call ready ${ready.sessionId}');
    } catch (e) {
      _append('call: $e');
    }
  }

  Future<void> _end() async {
    await _call?.end();
    await _chat?.close();
    _call = null;
    _chat = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_agentName.isEmpty ? 'Volai example' : _agentName)),
      body: Column(children: [
        Wrap(spacing: 8, children: [
          ElevatedButton(onPressed: _client == null ? null : _startChat, child: const Text('Start chat')),
          ElevatedButton(onPressed: _client == null ? null : _startCall, child: const Text('Start call')),
          ElevatedButton(onPressed: () => _call?.setMuted(true), child: const Text('Mute')),
          ElevatedButton(onPressed: _end, child: const Text('End')),
        ]),
        Row(children: [
          Expanded(child: TextField(controller: _message)),
          ElevatedButton(onPressed: _sendChat, child: const Text('Send')),
        ]),
        Expanded(child: ListView(children: _log.map((l) => Text(l)).toList())),
      ]),
    );
  }
}
