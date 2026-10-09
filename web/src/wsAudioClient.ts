// Browser client for the Volai ws_audio voice transport
// (docs/sdk/voice-ws-protocol.md). One WebSocket carries JSON control frames
// and raw PCM frames; no WebRTC. Microphone capture and playback run in
// AudioWorklets (inlined as blob modules so no bundler configuration is
// needed). This is the reference implementation the native SDKs mirror.
import { decodeFrame, encodeFrame } from './wsAudioFrames';

export type WsAudioMode = 'full_duplex' | 'half_duplex';
export type WsAudioState = 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'ended';

export interface WsAudioClientOptions {
  /** Socket URL from the session response (ws_audio transport). */
  wsUrl: string;
  sdk?: string;
  version?: string;
  platform?: string;
  mode?: WsAudioMode;
  /** Playback prebuffer before audio starts after a gap (ms). */
  prebufferMs?: number;
  /** Extra getUserMedia audio constraints. */
  audioConstraints?: MediaTrackConstraints;
}

export interface SessionReady {
  session_id: string;
  uplink: { rate: number; frame_ms: number; bytes: number };
  downlink: { rate: number; frame_ms: number; bytes: number };
  epoch: number;
  resume_token: string;
  grace_ms: number;
  resumed?: boolean;
}

type Listener = (payload: unknown) => void;

const CAPTURE_WORKLET = `
class VolaiCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.target = 16000;
    this.frame = Math.round(this.target * 0.02);
    this.ratio = sampleRate / this.target;
    this.pos = 0;
    this.pending = [];
    this.pendingLen = 0;
    this.out = new Int16Array(this.frame);
    this.outLen = 0;
  }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    this.pending.push(Float32Array.from(ch));
    this.pendingLen += ch.length;
    // Linear resample to 16 kHz, emit 20 ms frames.
    while (true) {
      const i0 = Math.floor(this.pos);
      if (i0 + 1 >= this.pendingLen) break;
      const frac = this.pos - i0;
      const a = this.sampleAt(i0), b = this.sampleAt(i0 + 1);
      let v = a + (b - a) * frac;
      v = Math.max(-1, Math.min(1, v));
      this.out[this.outLen++] = v < 0 ? v * 32768 : v * 32767;
      this.pos += this.ratio;
      if (this.outLen === this.frame) {
        const copy = this.out.slice(0);
        this.port.postMessage(copy, [copy.buffer]);
        this.outLen = 0;
      }
    }
    // Drop fully consumed chunks.
    while (this.pending.length > 0 && this.pos >= this.pending[0].length) {
      this.pos -= this.pending[0].length;
      this.pendingLen -= this.pending[0].length;
      this.pending.shift();
    }
    return true;
  }
  sampleAt(i) {
    let k = 0;
    while (k < this.pending.length && i >= this.pending[k].length) { i -= this.pending[k].length; k += 1; }
    return k < this.pending.length ? this.pending[k][i] : 0;
  }
}
registerProcessor('volai-capture', VolaiCapture);
`;

const PLAYBACK_WORKLET = `
class VolaiPlayback extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = (options && options.processorOptions) || {};
    this.sourceRate = o.sourceRate || 24000;
    this.step = this.sourceRate / sampleRate;
    this.prebuffer = Math.round((o.prebufferMs || 60) / 1000 * this.sourceRate);
    this.queue = [];
    this.queued = 0;
    this.pos = 0;
    this.primed = false;
    this.epoch = 0;
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'audio') {
        if (m.epoch !== this.epoch) return; // stale frame from before a flush
        this.queue.push(m.pcm);
        this.queued += m.pcm.length;
      } else if (m.type === 'flush') {
        this.epoch = m.epoch;
        this.queue = [];
        this.queued = 0;
        this.pos = 0;
        this.primed = false;
      } else if (m.type === 'query') {
        this.port.postMessage({ type: 'buffered', ms: Math.round(this.queued / this.sourceRate * 1000) });
      }
    };
  }
  process(inputs, outputs) {
    const out = outputs[0][0];
    if (!out) return true;
    if (!this.primed) {
      if (this.queued < this.prebuffer) { out.fill(0); return true; }
      this.primed = true;
    }
    for (let i = 0; i < out.length; i += 1) {
      if (this.queue.length === 0) {
        out.fill(0, i);
        this.primed = false;
        break;
      }
      const head = this.queue[0];
      const i0 = Math.floor(this.pos);
      const a = head[i0] / 32768;
      const next = i0 + 1 < head.length ? head[i0 + 1] : (this.queue[1] ? this.queue[1][0] : head[i0]);
      const b = next / 32768;
      out[i] = a + (b - a) * (this.pos - i0);
      this.pos += this.step;
      if (this.pos >= head.length) {
        this.pos -= head.length;
        this.queued -= head.length;
        this.queue.shift();
      }
    }
    return true;
  }
}
registerProcessor('volai-playback', VolaiPlayback);
`;

const blobModule = (code: string) => URL.createObjectURL(new Blob([code], { type: 'application/javascript' }));

export class VolaiWsAudioClient {
  readonly options: Required<Pick<WsAudioClientOptions, 'wsUrl' | 'mode' | 'prebufferMs'>> & WsAudioClientOptions;
  state: WsAudioState = 'idle';
  ready: SessionReady | null = null;
  muted = false;
  agentSpeaking = false;

  private ws: WebSocket | null = null;
  private listeners = new Map<string, Set<Listener>>();
  private captureCtx: AudioContext | null = null;
  private playbackCtx: AudioContext | null = null;
  private captureNode: AudioWorkletNode | null = null;
  private playbackNode: AudioWorkletNode | null = null;
  private playbackGain: GainNode | null = null;
  private playbackMuted = false;
  private stream: MediaStream | null = null;
  private seq = 0;
  private epoch = 0;
  private ended = false;
  private endRequested = false;
  private reconnectDeadline = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private lastPingAt = 0;
  rttMs: number | null = null;

  constructor(options: WsAudioClientOptions) {
    this.options = { mode: 'full_duplex', prebufferMs: 60, ...options };
  }

  on(event: string, listener: Listener): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(listener);
    return () => this.listeners.get(event)?.delete(listener);
  }

  private emit(event: string, payload?: unknown) {
    this.listeners.get(event)?.forEach((fn) => {
      try { fn(payload); } catch (e) { console.error('[ws_audio] listener error', e); }
    });
  }

  private setState(state: WsAudioState) {
    if (this.state === state) return;
    this.state = state;
    this.emit('state', state);
  }

  /**
   * Start playback, open the socket, then capture. Playback needs no
   * permission, so the greeting can play while the browser still shows the
   * microphone prompt; a denied microphone ends the call with `mic_denied`.
   * Resolves on session.ready.
   */
  async connect(): Promise<SessionReady> {
    if (this.state !== 'idle') throw new Error('connect() may only be called once');
    this.setState('connecting');
    await this.startPlayback();
    const ready = await this.openSocket(this.options.wsUrl);
    this.startCapture().catch((error: unknown) => {
      const name = (error as { name?: string })?.name || '';
      const code = name === 'NotAllowedError' || name === 'SecurityError' ? 'mic_denied' : 'mic_failed';
      this.emit('error', { type: 'error', code, message: (error as Error)?.message || String(error), fatal: true });
      this.end(code);
    });
    return ready;
  }

  private audioContextClass(): typeof AudioContext {
    return window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
  }

  private async startPlayback() {
    const Ctx = this.audioContextClass();
    // 24 kHz output when the browser allows it; the worklet resamples otherwise.
    try { this.playbackCtx = new Ctx({ sampleRate: 24000 }); } catch { this.playbackCtx = new Ctx(); }
    await this.playbackCtx.audioWorklet.addModule(blobModule(PLAYBACK_WORKLET));
    this.playbackNode = new AudioWorkletNode(this.playbackCtx, 'volai-playback', {
      numberOfInputs: 0,
      outputChannelCount: [1],
      processorOptions: { sourceRate: 24000, prebufferMs: this.options.prebufferMs },
    });
    this.playbackGain = this.playbackCtx.createGain();
    this.playbackGain.gain.value = this.playbackMuted ? 0 : 1;
    this.playbackNode.connect(this.playbackGain);
    this.playbackGain.connect(this.playbackCtx.destination);
    await this.playbackCtx.resume();
  }

  private async startCapture() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
        channelCount: 1,
        ...(this.options.audioConstraints || {}),
      },
    });
    if (this.ended) {
      this.stream.getTracks().forEach((t) => t.stop());
      return;
    }
    const Ctx = this.audioContextClass();
    // Capture at 16 kHz when the browser allows it; the worklet resamples otherwise.
    try { this.captureCtx = new Ctx({ sampleRate: 16000 }); } catch { this.captureCtx = new Ctx(); }
    await this.captureCtx.audioWorklet.addModule(blobModule(CAPTURE_WORKLET));
    const source = this.captureCtx.createMediaStreamSource(this.stream);
    this.captureNode = new AudioWorkletNode(this.captureCtx, 'volai-capture', { numberOfOutputs: 0 });
    this.captureNode.port.onmessage = (e: MessageEvent<Int16Array>) => this.sendUplink(e.data);
    source.connect(this.captureNode);
    this.stream.getAudioTracks().forEach((t) => { t.enabled = !this.muted; });
    await this.captureCtx.resume();
    this.emit('capture', true);
  }

  private openSocket(url: string): Promise<SessionReady> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      let settled = false;
      this.ws = ws;
      ws.onopen = () => {
        ws.send(JSON.stringify({
          type: 'client.hello',
          sdk: this.options.sdk || 'volai-web',
          version: this.options.version || '0.1.0',
          platform: this.options.platform || 'web',
          mode: this.options.mode,
        }));
      };
      ws.onmessage = (ev) => {
        if (ev.data instanceof ArrayBuffer) {
          this.onDownlink(ev.data);
          return;
        }
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(String(ev.data)); } catch { return; }
        if (msg.type === 'session.ready') {
          this.ready = msg as unknown as SessionReady;
          this.epoch = this.ready.epoch ?? 0;
          this.playbackNode?.port.postMessage({ type: 'flush', epoch: this.epoch });
          this.setState('connected');
          this.startPing();
          this.emit('ready', this.ready);
          if (!settled) { settled = true; resolve(this.ready); }
          return;
        }
        this.onControl(msg);
      };
      ws.onerror = () => {
        if (!settled) { settled = true; reject(new Error('Voice socket failed to connect')); }
      };
      ws.onclose = (ev) => {
        this.stopPing();
        if (!settled) { settled = true; reject(new Error(`Voice socket closed (${ev.code})`)); }
        this.onSocketClosed(ev.code);
      };
    });
  }

  private onSocketClosed(code: number) {
    if (this.ended) return;
    const clean = this.endRequested || code === 1000 || code === 1001 || code === 1008;
    if (clean || !this.ready) {
      this.finish(this.endRequested ? 'user_ended' : 'socket_closed');
      return;
    }
    // Abnormal drop: resume within the server's grace window.
    if (this.state !== 'reconnecting') {
      this.reconnectDeadline = Date.now() + (this.ready.grace_ms || 15000) - 1000;
      this.setState('reconnecting');
    }
    if (Date.now() >= this.reconnectDeadline) {
      this.finish('reconnect_failed');
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      const base = this.options.wsUrl.split('?')[0];
      const url = `${base}?resume_session=${encodeURIComponent(this.ready!.session_id)}&resume_token=${encodeURIComponent(this.ready!.resume_token)}`;
      this.openSocket(url).catch(() => { /* onclose schedules the next attempt */ });
    }, 500);
  }

  private onControl(msg: Record<string, unknown>) {
    switch (msg.type) {
      case 'audio.interrupted':
        this.epoch = Number(msg.epoch) & 0xff;
        this.playbackNode?.port.postMessage({ type: 'flush', epoch: this.epoch });
        this.ws?.send(JSON.stringify({ type: 'playback.flushed', epoch: this.epoch }));
        this.emit('interrupted', msg);
        break;
      case 'speakStart':
        this.agentSpeaking = true;
        this.emit('agentSpeaking', true);
        break;
      case 'speakEnd':
        this.agentSpeaking = false;
        this.emit('agentSpeaking', false);
        break;
      case 'speech':
        this.emit('transcript', { side: msg.side, text: msg.utterance, rejected: msg.rejected === true, raw: msg });
        break;
      case 'chunk':
        this.emit('chunk', msg);
        break;
      case 'pong':
        if (typeof msg.ts === 'number') this.rttMs = Date.now() - msg.ts;
        break;
      case 'session_ended':
      case 'SESSION_ENDED':
        this.ended = true;
        this.finish(String(msg.reason || 'agent_ended'));
        break;
      case 'error':
        this.emit('error', msg);
        if (msg.fatal) this.finish('error');
        break;
      case 'fatal_error':
        this.emit('error', msg);
        this.finish('error');
        break;
      default:
        this.emit('message', msg);
    }
  }

  private onDownlink(data: ArrayBuffer) {
    const frame = decodeFrame(data);
    if (!frame || !this.playbackNode) return;
    this.playbackNode.port.postMessage({ type: 'audio', epoch: frame.epoch, pcm: frame.pcm }, [frame.pcm.buffer]);
  }

  private sendUplink(pcm: Int16Array) {
    if (this.muted || !this.ws || this.ws.readyState !== WebSocket.OPEN || this.state === 'reconnecting') return;
    this.ws.send(encodeFrame(0, this.seq, pcm));
    this.seq = (this.seq + 1) & 0xffff;
  }

  private startPing() {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (this.ws?.readyState !== WebSocket.OPEN) return;
      this.lastPingAt = Date.now();
      this.ws.send(JSON.stringify({ type: 'ping', ts: this.lastPingAt }));
      if (this.rttMs != null) this.ws.send(JSON.stringify({ type: 'stats', rtt_ms: this.rttMs }));
    }, 5000);
  }

  private stopPing() {
    if (this.pingTimer) { clearInterval(this.pingTimer); this.pingTimer = null; }
  }

  /** Silence local playback without stopping the stream (e.g. an avatar replays the audio). */
  setPlaybackMuted(muted: boolean) {
    this.playbackMuted = muted;
    if (this.playbackGain) this.playbackGain.gain.value = muted ? 0 : 1;
  }

  setMuted(muted: boolean) {
    this.muted = muted;
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = !muted; });
    this.ws?.send(JSON.stringify({ type: 'mic.muted', muted }));
    this.emit('muted', muted);
  }

  /** Hang up: tells the server, then releases audio devices. */
  end(reason = 'user_hangup') {
    if (this.ended) return;
    this.endRequested = true;
    try { this.ws?.send(JSON.stringify({ type: 'session.end', reason })); } catch { /* closed */ }
    try { this.ws?.close(1000, 'end'); } catch { /* closed */ }
    this.finish('user_ended');
  }

  private finish(reason: string) {
    if (this.state === 'ended') return;
    this.ended = true;
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.stopPing();
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    try { this.captureNode?.disconnect(); } catch { /* gone */ }
    try { this.playbackNode?.disconnect(); } catch { /* gone */ }
    this.captureCtx?.close().catch(() => {});
    this.playbackCtx?.close().catch(() => {});
    this.captureCtx = null;
    this.playbackCtx = null;
    if (this.ws && this.ws.readyState === WebSocket.OPEN) { try { this.ws.close(1000); } catch { /* closed */ } }
    this.ws = null;
    this.setState('ended');
    this.emit('ended', reason);
  }
}
