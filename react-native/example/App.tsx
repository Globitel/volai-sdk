import React, { useEffect, useRef, useState } from 'react';
import { Button, PermissionsAndroid, Platform, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { VolaiClient, VolaiVoiceCall, VolaiChatSession } from '@volai/react-native-sdk';

// Fill these in for your environment. On a development stack use the host
// machine's address (10.0.2.2 on the Android emulator) and a wsBase on the
// dev WebSocket port.
const CONFIG = {
  baseUrl: 'https://gicc.globitel.com',
  appKey: '',
  agentId: '',
  wsBase: '',
};

export default function App() {
  const [log, setLog] = useState<string[]>([]);
  const [agentName, setAgentName] = useState('');
  const [message, setMessage] = useState('Hello');
  const client = useRef<VolaiClient | null>(null);
  const chat = useRef<VolaiChatSession | null>(null);
  const call = useRef<VolaiVoiceCall | null>(null);
  const append = (line: string) => setLog((l) => [...l.slice(-40), line]);

  useEffect(() => {
    if (!CONFIG.appKey) { append('Set CONFIG in App.tsx'); return; }
    client.current = new VolaiClient({ baseUrl: CONFIG.baseUrl, appKey: CONFIG.appKey });
    client.current.getAgent(CONFIG.agentId).then((a) => setAgentName(`${a.name} (${a.defaultVoiceTransport})`)).catch((e) => append(`agent: ${e.message}`));
  }, []);

  const startChat = async () => {
    try {
      chat.current = await client.current!.createChat({ agentId: CONFIG.agentId, deviceId: 'rn-example' });
      chat.current.onEvent((e) => { if (e.type === 'chat' || e.type === 'chunk') append(`agent: ${String(e.content ?? '')}`); });
      await chat.current.start();
      append('chat started');
    } catch (e) { append(`chat: ${(e as Error).message}`); }
  };

  const sendChat = async () => {
    try { await chat.current?.send(message); append(`you: ${message}`); } catch (e) { append(`send: ${(e as Error).message}`); }
  };

  const startCall = async () => {
    try {
      if (Platform.OS === 'android') {
        const granted = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
        if (granted !== PermissionsAndroid.RESULTS.GRANTED) { append('microphone denied'); return; }
      }
      call.current = await client.current!.createVoice({ agentId: CONFIG.agentId, deviceId: 'rn-example' });
      if (CONFIG.wsBase) await call.current.setSocketUrlOverride(call.current.info.wsUrl.replace(/^wss?:\/\/[^/]+/, CONFIG.wsBase));
      call.current.onEvent((e) => {
        if (e.type === 'transcript') append(`${e.side}: ${e.text}`);
        else if (e.type === 'state' || e.type === 'ended' || e.type === 'error' || e.type === 'interrupted') append(JSON.stringify(e));
      });
      const ready = await call.current.connect();
      append(`call ready ${ready.session_id}`);
    } catch (e) { append(`call: ${(e as Error).message}`); }
  };

  return (
    <SafeAreaView style={styles.container}>
      <Text style={styles.title}>Volai SDK example</Text>
      <Text>{agentName || 'agent not loaded'}</Text>
      <View style={styles.row}>
        <Button title="Start chat" onPress={startChat} />
        <Button title="Start call" onPress={startCall} />
        <Button title="Mute" onPress={() => call.current?.setMuted(true)} />
        <Button title="End" onPress={() => { call.current?.end(); chat.current?.close(); }} />
      </View>
      <View style={styles.row}>
        <TextInput style={styles.input} value={message} onChangeText={setMessage} />
        <Button title="Send" onPress={sendChat} />
      </View>
      <ScrollView style={styles.log}>{log.map((l, i) => <Text key={i} style={styles.line}>{l}</Text>)}</ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 16 },
  title: { fontSize: 20, fontWeight: '600', marginBottom: 8 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginVertical: 8, alignItems: 'center' },
  input: { flex: 1, borderWidth: 1, borderColor: '#ccc', borderRadius: 6, padding: 8 },
  log: { flex: 1, marginTop: 8 },
  line: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 12, marginBottom: 2 },
});
