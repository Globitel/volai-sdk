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
  /**
   * What the app draws itself. With 'interactive', a question with options
   * arrives as an `interactive` event carrying an InteractiveMessage; without
   * it the same question arrives as numbered text inside the reply. With
   * 'forms' as well, a form arrives as an `interactive` event of kind 'form'
   * (InteractiveForm); without it the customer is asked one question per
   * message. With 'cards', structured information arrives as an
   * InteractiveCard. With 'client_actions', a guided flow may hand a step to
   * the app as a `client_action` event (ClientAction).
   */
  capabilities?: Array<'interactive' | 'forms' | 'cards' | 'client_actions'>;
  /**
   * The language of the app's own screens, as a short tag ('ar', 'en').
   * When it is one of the agent's languages the conversation starts and stays
   * in it: the greeting, the agent's replies and translated forms. Anything
   * else is ignored and the agent's own language setting applies.
   */
  language?: string;
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

export interface InteractiveOption {
  id: string;
  title: string;
  description?: string;
  /** Absolute https URL. */
  image?: { url: string };
}

/**
 * A question with options for the app to draw (`interactive` event,
 * field `interactive`). `layout` is a hint: 'buttons' (up to three short
 * options), 'list', or 'cards' (options with pictures). Answer with
 * `VolaiChatSession.reply`; the event's `content` holds the same question as
 * numbered text. An `interactive_answered` event ({ id, option_ids, source })
 * follows the first answer, also when the customer typed it: lock the options.
 */
export interface InteractiveMessage {
  id: string;
  kind: 'choices';
  text: string;
  layout: 'buttons' | 'list' | 'cards';
  multi: boolean;
  options: InteractiveOption[];
  image?: { url: string };
  /** Label for a control that opens the list, in the conversation language. */
  button_label: string;
}

/**
 * Structured information for the app to draw (`interactive` event, kind
 * 'card'). `fields` are generic; `template` and `data` name the app's own
 * card and carry its raw values, passed through from the agent. Answer an
 * action with `VolaiChatSession.reply(id, [actionId])`.
 */
export interface InteractiveCard {
  id: string;
  kind: 'card';
  text: string;
  body?: string;
  image?: { url: string };
  fields: { label: string; value: string; progress?: number }[];
  actions: { id: string; title: string }[];
  template?: string;
  data?: Record<string, unknown>;
}

export interface InteractiveFormField {
  key: string;
  label: string;
  type: 'text' | 'textarea' | 'number' | 'select' | 'multiselect' | 'date' | 'checkbox' | 'rating' | 'scale' | 'tags';
  required?: boolean;
  options?: { value: string; label: string }[];
  max_length?: number;
  pattern?: string;
  pattern_hint?: string;
  help?: string;
  sensitive?: boolean;
  visible_when?: { field: string; equals: string | boolean };
}

/**
 * A form for the app to draw (`interactive` event, kind 'form'). Labels are
 * in the conversation language. Answer with `VolaiChatSession.submitForm` or
 * `cancelForm`; `interactive_answered` ({ id, outcome, values }) closes it.
 */
export interface InteractiveForm {
  id: string;
  kind: 'form';
  text: string;
  form_key: string;
  language: string;
  form: { title: string; submit_label: string; intro?: string; fields: InteractiveFormField[] };
  /** Values the agent already knew, by field key. */
  prefill: Record<string, unknown>;
}

/**
 * A step of a guided flow that the app carries out in its own screens: a
 * login, a payment (`client_action` event; the fields sit on the event
 * itself). Do the work, then give `token` to your backend, which reports the
 * result with the secret key (`POST /client-actions/complete`). The app can
 * only say that the step was cancelled or failed:
 * `VolaiChatSession.reportClientAction`. The flow's next message arrives on
 * the event stream. The token lasts 30 minutes; the event is not replayed
 * after a reconnect.
 */
export interface ClientAction {
  type: 'client_action';
  id: string;
  /** The action's name as the flow's author wrote it, e.g. 'payment'. */
  action: string;
  params: Record<string, unknown>;
  token: string;
  /** Text to show the customer while the app works. */
  content: string;
}

/** A file attached to a chat message, as stored in the conversation history. `url` is portal-relative. */
export interface ChatAttachment {
  url: string;
  filename: string;
  mimetype: string;
  size: number;
}

export interface UploadedAttachment {
  attachment: ChatAttachment;
  /** Absolute URL of the file, for rendering from another origin. */
  download_url: string;
  /** Server cap on one file, in bytes. */
  max_bytes: number;
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

  async send(content: string, options: { messageId?: string; attachment?: ChatAttachment } = {}): Promise<Record<string, unknown>> {
    const messageId = options.messageId || crypto.randomUUID();
    return this.client.request(`/sessions/${this.info.session_id}/messages`, {
      method: 'POST', key: this.info.chat_token,
      body: { message_id: messageId, content, ...(options.attachment ? { attachment: options.attachment } : {}) },
      raw: true,
    }) as Promise<Record<string, unknown>>;
  }

  /**
   * Answer an interactive message with the options the customer tapped. The
   * server records the chosen titles as the customer's message; the reply
   * arrives like the reply to any message. 409 `interactive_not_found` when
   * the question is not part of this session.
   */
  async reply(interactiveId: string, optionIds: string[], options: { messageId?: string } = {}): Promise<Record<string, unknown>> {
    const messageId = options.messageId || crypto.randomUUID();
    return this.client.request(`/sessions/${this.info.session_id}/messages`, {
      method: 'POST', key: this.info.chat_token,
      body: { message_id: messageId, interaction_reply: { interactive_id: interactiveId, option_ids: optionIds } },
      raw: true,
    }) as Promise<Record<string, unknown>>;
  }

  /**
   * Send a form's answers by field key. Throws VolaiApiError 422 with
   * `body.reason === 'invalid_form'` and `body.errors` (one message per field
   * key) when the server refuses them: show the errors and keep the form open.
   */
  async submitForm(interactiveId: string, values: Record<string, unknown>, options: { messageId?: string } = {}): Promise<Record<string, unknown>> {
    const messageId = options.messageId || crypto.randomUUID();
    return this.client.request(`/sessions/${this.info.session_id}/messages`, {
      method: 'POST', key: this.info.chat_token,
      body: { message_id: messageId, interaction_reply: { interactive_id: interactiveId, values } },
      raw: true,
    }) as Promise<Record<string, unknown>>;
  }

  /** Close a form without sending it. */
  async cancelForm(interactiveId: string, options: { messageId?: string } = {}): Promise<Record<string, unknown>> {
    const messageId = options.messageId || crypto.randomUUID();
    return this.client.request(`/sessions/${this.info.session_id}/messages`, {
      method: 'POST', key: this.info.chat_token,
      body: { message_id: messageId, interaction_reply: { interactive_id: interactiveId, cancelled: true } },
      raw: true,
    }) as Promise<Record<string, unknown>>;
  }

  /**
   * Tell the flow that a client action was cancelled by the customer or
   * failed in the app. Success cannot be reported from the app: your backend
   * reports it with the secret key. 409 when the action no longer waits.
   */
  async reportClientAction(actionId: string, outcome: 'cancelled' | 'failed'): Promise<Record<string, unknown>> {
    return this.client.request(`/sessions/${this.info.session_id}/client-actions/${encodeURIComponent(actionId)}`, {
      method: 'POST', key: this.info.chat_token, body: { outcome },
    }) as Promise<Record<string, unknown>>;
  }

  /**
   * Upload a file for this conversation (multipart, field `file`), at any
   * point of the chat. With a human agent on the chat the file reaches the
   * agent; while the AI owns it the AI agent's Attachments setting answers
   * (an automatic reply, optionally a transfer to a human agent). Servers
   * older than 1.3.104 answer 409 with `reason: attachments_unavailable`
   * before a transfer. One file, up to `max_bytes` (10 MB); images, audio,
   * mp4/webm/ogg, PDF, Office documents, text and CSV.
   */
  async uploadAttachment(file: Blob, options: { filename?: string; signal?: AbortSignal } = {}): Promise<UploadedAttachment> {
    const form = new FormData();
    const filename = options.filename || (file as File).name || 'attachment';
    form.append('file', file, filename);
    const res = await this.client.fetch(`${this.client.options.baseUrl}/gicc/api/sdk/v1/sessions/${this.info.session_id}/attachments`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.info.chat_token}` },
      body: form,
      signal: options.signal,
    });
    const text = await res.text();
    let json: Record<string, unknown> = {};
    try { json = JSON.parse(text); } catch { json = {}; }
    if (!res.ok) throw new VolaiApiError(res.status, json);
    return json as unknown as UploadedAttachment;
  }

  /**
   * Upload a file and send it as a message in one step. The caption defaults
   * to `Sent a file: <name>`, which the agent desktop renders as a bare
   * attachment. Resolves with the message id and the stored attachment.
   */
  async sendAttachment(file: Blob, options: { filename?: string; content?: string; messageId?: string; signal?: AbortSignal } = {}): Promise<{ messageId: string; attachment: ChatAttachment; download_url: string }> {
    const uploaded = await this.uploadAttachment(file, { filename: options.filename, signal: options.signal });
    const messageId = options.messageId || crypto.randomUUID();
    const content = options.content || `Sent a file: ${uploaded.attachment.filename}`;
    await this.send(content, { messageId, attachment: uploaded.attachment });
    return { messageId, attachment: uploaded.attachment, download_url: uploaded.download_url };
  }

  /** Absolute URL for an attachment received on the event stream (`human_chat` / `chat` events carry `attachment`). */
  attachmentUrl(attachment: ChatAttachment): string {
    return /^https?:\/\//i.test(attachment.url) ? attachment.url : `${this.client.options.baseUrl}${attachment.url}`;
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
        ...(input.capabilities?.length ? { capabilities: input.capabilities } : {}),
        ...(input.language ? { language: input.language } : {}),
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
