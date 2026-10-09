// REST side of the Volai SDK contract (docs/sdk/openapi.yaml): agent lookup,
// session creation, chat over REST + SSE, and session grants. Pairs with
// VolaiWsAudioClient for voice. Browser-first (fetch, EventSource-free SSE
// parsing so it also runs under React Native with a fetch polyfill).
import { VolaiWsAudioClient, type WsAudioClientOptions, type WsAudioMode } from './wsAudioClient';

export interface VolaiClientOptions {
  /** e.g. https://gicc.globitel.com */
  baseUrl: string;
  /** Publishable `sdk` key. */
  appKey: string;
  sdkName?: string;
  sdkVersion?: string;
  platform?: string;
  fetchImpl?: typeof fetch;
}

export interface PublicAgent {
  api_id: string;
  name: string;
  description?: string;
  type?: string;
  agentArchitecture?: string;
  embedMode?: 'chat' | 'voice' | 'both';
  voiceTransports: Array<'webrtc' | 'ws_audio'>;
  defaultVoiceTransport: 'webrtc' | 'ws_audio';
  publicLinkPasswordRequired?: boolean;
  widgetContactFields?: { askPhone?: boolean; askName?: boolean; askEmail?: boolean; verifyPhone?: boolean; verifyEmail?: boolean };
  [key: string]: unknown;
}

export interface CreateSessionInput {
  agentId: string;
  type: 'voice' | 'chat';
  transport?: 'ws_audio' | 'webrtc';
  deviceId?: string;
  callerName?: string;
  callerPhone?: string;
  callerEmail?: string;
  context?: Record<string, unknown>;
  verificationTokens?: { phone?: string | string[]; email?: string | string[] };
  sessionGrant?: string;
  publicLinkPassword?: string;
}

export interface VoiceSessionInfo {
  session_id: string;
  type: 'voice';
  transport: 'ws_audio' | 'webrtc';
  ws_url: string;
  ws_token: string;
  ws_token_expires_in: number;
}

export interface ChatSessionInfo {
  session_id: string;
  type: 'chat';
  chat_token: string;
  events_url: string;
  initial_greeting: { id: string; content: string } | null;
  idle_minutes: number | null;
  expires_at: string | null;
}

export class VolaiApiError extends Error {
  status: number;
  code?: string;
  reason?: string;
  body: unknown;
  constructor(status: number, body: Record<string, unknown>) {
    super(String(body?.message || `Volai API error ${status}`));
    this.name = 'VolaiApiError';
    this.status = status;
    this.code = body?.code as string | undefined;
    this.reason = body?.reason as string | undefined;
    this.body = body;
  }
}

type ChatListener = (event: Record<string, unknown>) => void;

/** A REST chat session: send messages, acknowledge, and receive events over SSE. */
export class VolaiChatSession {
  readonly info: ChatSessionInfo;
  private client: VolaiClient;
  private abort: AbortController | null = null;
  private listeners = new Set<ChatListener>();
  private cursor: string | null = null;
  closed = false;

  constructor(client: VolaiClient, info: ChatSessionInfo) {
    this.client = client;
    this.info = info;
  }

  onEvent(listener: ChatListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Open the event stream; reconnects with the last cursor until closed. */
  async start(): Promise<void> {
    if (this.abort) return;
    this.abort = new AbortController();
    const run = async () => {
      while (!this.closed && this.abort && !this.abort.signal.aborted) {
        try {
          const url = new URL(this.info.events_url);
          url.searchParams.set('chat_token', this.info.chat_token);
          if (this.cursor) url.searchParams.set('cursor', this.cursor);
          const res = await this.client.fetch(url.toString(), { headers: { Accept: 'text/event-stream' }, signal: this.abort.signal });
          if (res.status === 401 || res.status === 404) { this.closed = true; this.emit({ type: 'SESSION_ENDED', reason: 'token_rejected' }); return; }
          await this.pump(res);
        } catch (e) {
          if (this.abort?.signal.aborted || this.closed) return;
          this.emit({ type: 'stream_error', message: (e as Error).message });
        }
        if (!this.closed) await new Promise((r) => setTimeout(r, 1000));
      }
    };
    void run();
  }

  private async pump(res: Response) {
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buffer.indexOf('\n\n')) >= 0) {
        const block = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        let data = '';
        for (const line of block.split('\n')) {
          if (line.startsWith('id:')) this.cursor = line.slice(3).trim();
          else if (line.startsWith('data:')) data += line.slice(5).trim();
        }
        if (!data) continue;
        try {
          const event = JSON.parse(data) as Record<string, unknown>;
          if (typeof event.id === 'string' && event.type !== 'ack') this.cursor = this.cursor || null;
          this.emit(event);
          if (event.type === 'SESSION_ENDED') { this.closed = true; return; }
        } catch { /* keepalive or partial */ }
      }
    }
  }

  private emit(event: Record<string, unknown>) {
    this.listeners.forEach((fn) => { try { fn(event); } catch (e) { console.error('[volai] chat listener error', e); } });
  }

  async send(content: string, options: { messageId?: string; attachment?: unknown } = {}): Promise<Record<string, unknown>> {
    const messageId = options.messageId || crypto.randomUUID();
    return this.client.request(`/sessions/${this.info.session_id}/messages`, {
      method: 'POST', key: this.info.chat_token,
      body: { message_id: messageId, content, ...(options.attachment ? { attachment: options.attachment } : {}) },
      raw: true,
    }) as Promise<Record<string, unknown>>;
  }

  async acknowledge(messageId: string, status: 'delivered' | 'read'): Promise<void> {
    await this.client.request(`/sessions/${this.info.session_id}/acks`, { method: 'POST', key: this.info.chat_token, body: { message_id: messageId, status } });
  }

  async typing(): Promise<void> {
    await this.client.request(`/sessions/${this.info.session_id}/typing`, { method: 'POST', key: this.info.chat_token });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abort?.abort();
    this.abort = null;
    await this.client.request(`/sessions/${this.info.session_id}/close`, { method: 'POST', key: this.info.chat_token }).catch(() => undefined);
  }
}

export class VolaiClient {
  readonly options: VolaiClientOptions;
  readonly fetch: typeof fetch;

  constructor(options: VolaiClientOptions) {
    this.options = { ...options, baseUrl: options.baseUrl.replace(/\/+$/, '') };
    this.fetch = options.fetchImpl || ((input, init) => fetch(input, init));
  }

  /** Low-level call against /gicc/api/sdk/v1. Throws VolaiApiError on 4xx/5xx. */
  async request(path: string, { method = 'GET', key = this.options.appKey, body, raw = false }: { method?: string; key?: string | null; body?: unknown; raw?: boolean } = {}): Promise<unknown> {
    const res = await this.fetch(`${this.options.baseUrl}/gicc/api/sdk/v1${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...(key ? { Authorization: `Bearer ${key}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json: Record<string, unknown> = {};
    try { json = JSON.parse(text); } catch { json = raw ? { raw: text } : {}; }
    if (!res.ok) throw new VolaiApiError(res.status, json);
    return raw && !Object.keys(json).length ? { raw: text } : json;
  }

  getAgent(agentId: string): Promise<PublicAgent> {
    return this.request(`/agents/${encodeURIComponent(agentId)}`) as Promise<PublicAgent>;
  }

  sendVerificationCode(agentId: string, channel: 'phone' | 'email', destination: string, language?: string): Promise<unknown> {
    return this.request(`/agents/${encodeURIComponent(agentId)}/verification/send`, { method: 'POST', body: { channel, destination, ...(language ? { language } : {}) } });
  }

  checkVerificationCode(agentId: string, channel: 'phone' | 'email', destination: string, code: string): Promise<{ verification_token: string; expires_at: string }> {
    return this.request(`/agents/${encodeURIComponent(agentId)}/verification/check`, { method: 'POST', body: { channel, destination, code } }) as Promise<{ verification_token: string; expires_at: string }>;
  }

  createSession(input: CreateSessionInput): Promise<VoiceSessionInfo | ChatSessionInfo> {
    return this.request('/sessions', {
      method: 'POST',
      body: {
        agent_id: input.agentId,
        type: input.type,
        ...(input.transport ? { transport: input.transport } : {}),
        ...(input.deviceId ? { device_id: input.deviceId } : {}),
        ...(input.callerName ? { caller_name: input.callerName } : {}),
        ...(input.callerPhone ? { caller_phone: input.callerPhone } : {}),
        ...(input.callerEmail ? { caller_email: input.callerEmail } : {}),
        ...(input.context ? { context: input.context } : {}),
        ...(input.verificationTokens ? { verification_tokens: input.verificationTokens } : {}),
        ...(input.sessionGrant ? { session_grant: input.sessionGrant } : {}),
        ...(input.publicLinkPassword ? { public_link_password: input.publicLinkPassword } : {}),
      },
    }) as Promise<VoiceSessionInfo | ChatSessionInfo>;
  }

  /** Create a chat session and return a session object with the event stream not yet started. */
  async createChat(input: Omit<CreateSessionInput, 'type'>): Promise<VolaiChatSession> {
    const info = (await this.createSession({ ...input, type: 'chat' })) as ChatSessionInfo;
    return new VolaiChatSession(this, info);
  }

  /**
   * Create a voice session and return a ws_audio client ready to connect().
   * Throws when the server picked a transport this client does not speak.
   */
  async createVoice(input: Omit<CreateSessionInput, 'type'>, audio: Partial<Omit<WsAudioClientOptions, 'wsUrl'>> & { mode?: WsAudioMode } = {}): Promise<{ info: VoiceSessionInfo; voice: VolaiWsAudioClient }> {
    const info = (await this.createSession({ ...input, type: 'voice', transport: input.transport || 'ws_audio' })) as VoiceSessionInfo;
    if (info.transport !== 'ws_audio') throw new Error(`Server picked transport "${info.transport}", which this client does not implement`);
    const voice = new VolaiWsAudioClient({
      wsUrl: info.ws_url,
      sdk: this.options.sdkName || 'volai-web',
      version: this.options.sdkVersion || '0.1.0',
      platform: this.options.platform || 'web',
      ...audio,
    });
    return { info, voice };
  }
}
