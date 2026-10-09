// @volai/react-native-sdk — thin JavaScript layer over the native Volai
// libraries (ios/VolaiSDK, android volai-sdk). The protocol, audio and
// reconnect logic live in the native code; this file exposes the same shape
// as the other SDKs: VolaiClient, chat sessions and voice calls.
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

type Json = Record<string, unknown>;

interface NativeVolaiSdk {
  configure(baseUrl: string, appKey: string): Promise<void>;
  getAgent(agentId: string): Promise<Json>;
  createChat(request: Json): Promise<Json>;
  startChat(sessionId: string): Promise<void>;
  sendChatMessage(sessionId: string, content: string, messageId: string | null): Promise<string>;
  ackChatMessage(sessionId: string, messageId: string, status: string): Promise<void>;
  chatTyping(sessionId: string): Promise<void>;
  closeChat(sessionId: string): Promise<void>;
  createVoice(request: Json, mode: string): Promise<Json>;
  connectVoice(callId: string): Promise<Json>;
  setVoiceMuted(callId: string, muted: boolean): Promise<void>;
  setVoicePlaybackMuted(callId: string, muted: boolean): Promise<void>;
  endVoice(callId: string, reason: string): Promise<void>;
  setSocketUrlOverride(callId: string, url: string | null): Promise<void>;
}

const native: NativeVolaiSdk | undefined = NativeModules.VolaiSdk;
if (!native) {
  throw new Error(
    `@volai/react-native-sdk: native module not found. Rebuild the app after installing the package (${Platform.OS}).`,
  );
}
const emitter = new NativeEventEmitter(NativeModules.VolaiSdk);

export interface SessionRequest {
  agentId: string;
  deviceId?: string;
  callerName?: string;
  callerPhone?: string;
  callerEmail?: string;
  context?: Record<string, string | number | boolean>;
  verificationTokens?: { phone?: string | string[]; email?: string | string[] };
  sessionGrant?: string;
  publicLinkPassword?: string;
}

export interface PublicAgent {
  api_id: string;
  name: string;
  agentArchitecture?: string;
  embedMode?: string;
  voiceTransports: string[];
  defaultVoiceTransport: string;
  [key: string]: unknown;
}

export interface ChatSessionInfo {
  sessionId: string;
  chatToken: string;
  eventsUrl: string;
  initialGreeting: { id: string; content: string } | null;
}

export interface VoiceCallInfo {
  callId: string;
  sessionId: string;
  transport: string;
  wsUrl: string;
  wsTokenExpiresIn: number;
}

export interface SessionReady {
  session_id: string;
  epoch: number;
  resume_token: string;
  grace_ms: number;
  resumed?: boolean;
  uplink?: { rate: number; frame_ms: number };
  downlink?: { rate: number; frame_ms: number };
}

export type VoiceState = 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'ended';

export type VoiceEvent =
  | { type: 'ready'; ready: SessionReady }
  | { type: 'state'; state: VoiceState }
  | { type: 'transcript'; side: string; text: string; raw: Json }
  | { type: 'agentSpeaking'; speaking: boolean }
  | { type: 'interrupted'; epoch: number; reason: string }
  | { type: 'system'; content: string }
  | { type: 'message'; raw: Json }
  | { type: 'error'; code: string | null; message: string; fatal: boolean }
  | { type: 'ended'; reason: string };

export class VolaiChatSession {
  readonly info: ChatSessionInfo;
  private subscription: { remove(): void } | null = null;
  private listeners = new Set<(event: Json) => void>();
  closed = false;

  constructor(info: ChatSessionInfo) {
    this.info = info;
  }

  onEvent(listener: (event: Json) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Opens the event stream. Idempotent. */
  async start(): Promise<void> {
    if (this.subscription) return;
    this.subscription = emitter.addListener('VolaiChatEvent', (raw: unknown) => {
      const payload = raw as { sessionId: string; event: Json };
      if (payload.sessionId !== this.info.sessionId) return;
      this.listeners.forEach((fn) => { try { fn(payload.event); } catch (e) { console.error('[volai] chat listener', e); } });
      if (payload.event.type === 'SESSION_ENDED') this.closed = true;
    });
    await native!.startChat(this.info.sessionId);
  }

  send(content: string, messageId?: string): Promise<string> {
    return native!.sendChatMessage(this.info.sessionId, content, messageId ?? null);
  }

  acknowledge(messageId: string, status: 'delivered' | 'read'): Promise<void> {
    return native!.ackChatMessage(this.info.sessionId, messageId, status);
  }

  typing(): Promise<void> {
    return native!.chatTyping(this.info.sessionId);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.subscription?.remove();
    this.subscription = null;
    await native!.closeChat(this.info.sessionId).catch(() => undefined);
  }
}

export class VolaiVoiceCall {
  readonly info: VoiceCallInfo;
  state: VoiceState = 'idle';
  ready: SessionReady | null = null;
  private subscription: { remove(): void } | null;
  private listeners = new Set<(event: VoiceEvent) => void>();

  constructor(info: VoiceCallInfo) {
    this.info = info;
    this.subscription = emitter.addListener('VolaiVoiceEvent', (raw: unknown) => {
      const payload = raw as { callId: string } & VoiceEvent;
      if (payload.callId !== this.info.callId) return;
      const { callId: _ignored, ...event } = payload;
      if (event.type === 'state') this.state = event.state;
      if (event.type === 'ready') this.ready = event.ready;
      this.listeners.forEach((fn) => { try { fn(event as VoiceEvent); } catch (e) { console.error('[volai] voice listener', e); } });
      if (event.type === 'ended') { this.subscription?.remove(); this.subscription = null; }
    });
  }

  onEvent(listener: (event: VoiceEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Opens the call; resolves with session.ready. Request microphone permission first. */
  async connect(): Promise<SessionReady> {
    const ready = (await native!.connectVoice(this.info.callId)) as unknown as SessionReady;
    this.ready = ready;
    return ready;
  }

  setMuted(muted: boolean): Promise<void> {
    return native!.setVoiceMuted(this.info.callId, muted);
  }

  setPlaybackMuted(muted: boolean): Promise<void> {
    return native!.setVoicePlaybackMuted(this.info.callId, muted);
  }

  end(reason = 'user_hangup'): Promise<void> {
    return native!.endVoice(this.info.callId, reason);
  }

  /** Development only: rewrite the socket origin (e.g. a dev stack's separate WebSocket port). */
  setSocketUrlOverride(url: string | null): Promise<void> {
    return native!.setSocketUrlOverride(this.info.callId, url);
  }
}

export class VolaiClient {
  private readonly configured: Promise<void>;

  constructor(options: { baseUrl: string; appKey: string }) {
    this.configured = native!.configure(options.baseUrl, options.appKey);
  }

  async getAgent(agentId: string): Promise<PublicAgent> {
    await this.configured;
    return (await native!.getAgent(agentId)) as unknown as PublicAgent;
  }

  async createChat(request: SessionRequest): Promise<VolaiChatSession> {
    await this.configured;
    const info = (await native!.createChat(request as unknown as Json)) as unknown as ChatSessionInfo;
    return new VolaiChatSession(info);
  }

  async createVoice(request: SessionRequest, mode: 'full_duplex' | 'half_duplex' = 'full_duplex'): Promise<VolaiVoiceCall> {
    await this.configured;
    const info = (await native!.createVoice(request as unknown as Json, mode)) as unknown as VoiceCallInfo;
    return new VolaiVoiceCall(info);
  }
}

export const SDK_CONTRACT_VERSION = 1;
