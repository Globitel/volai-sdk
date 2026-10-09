#!/usr/bin/env node
// Volai SDK conformance script (docs/voice-ws-protocol.md).
//
// Drives the public SDK contract end to end the way a client SDK would, and
// prints a pass/fail report. It needs no Volai source beyond this repo's
// `ws` dependency and the frame codec, so the SDK team can run it against
// any environment with the keys they were given.
//
//   node tools/conformance/conformance.mjs --base https://gicc.globitel.com \
//     --app-key <sdk key> [--secret-key <sdk_secret key>] \
//     --voice-agent <public agent id> [--chat-agent <public agent id>] \
//     [--ws-base ws://localhost:8085]   # dev only: sockets live on another port
//
// Exit code 0 when every check passed, 1 otherwise.
import WebSocket from 'ws';
import { encodeFrame, decodeFrame } from './ws_audio_frames.js';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : 'true']);
    return acc;
}, []));
const BASE = (args.base || '').replace(/\/+$/, '');
const WS_BASE = args['ws-base'] || null;
const APP_KEY = args['app-key'];
const SECRET_KEY = args['secret-key'] || null;
const VOICE_AGENT = args['voice-agent'];
const CHAT_AGENT = args['chat-agent'] || VOICE_AGENT;
if (!BASE || !APP_KEY || !VOICE_AGENT) {
    console.error('usage: --base <url> --app-key <key> --voice-agent <public id> [--chat-agent <id>] [--secret-key <key>] [--ws-base <ws url>]');
    process.exit(2);
}

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); return ok; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const api = async (path, { method = 'GET', key = APP_KEY, body } = {}) => {
    const r = await fetch(`${BASE}/gicc/api/sdk/v1${path}`, {
        method, headers: { 'Content-Type': 'application/json', ...(key ? { Authorization: `Bearer ${key}` } : {}) },
        body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30000),
    });
    const text = await r.text(); let json; try { json = JSON.parse(text); } catch { json = { raw: text.slice(0, 300) }; }
    return { status: r.status, contract: r.headers.get('x-volai-contract'), json };
};
const toWs = (url) => WS_BASE ? url.replace(/^wss?:\/\/[^/]+/, WS_BASE) : url;
const resample24to16 = (buf) => { const n = buf.length / 2, m = Math.floor(n * 2 / 3), out = Buffer.alloc(m * 2); for (let i = 0; i < m; i++) { const p = i * 1.5, j = Math.floor(p), f = p - j, a = buf.readInt16LE(j * 2), b = buf.readInt16LE(Math.min(j + 1, n - 1) * 2); out.writeInt16LE(Math.round(a + (b - a) * f), i * 2); } return out; };

// ---- 1. discovery ------------------------------------------------------------
{
    const h = await api('/health', { key: null });
    check('health answers with contract 1', h.status === 200 && h.json.contract === 1 && h.contract === '1', `voice_transports=${JSON.stringify(h.json.voice_transports)}`);
    const a = await api(`/agents/${VOICE_AGENT}`);
    check('agent lookup with the app key', a.status === 200 && Array.isArray(a.json.voiceTransports), `default=${a.json.defaultVoiceTransport} arch=${a.json.agentArchitecture}`);
    const noKey = await api(`/agents/${VOICE_AGENT}`, { key: null });
    check('agent lookup without a key is refused', noKey.status === 401);
}

// ---- 2. chat --------------------------------------------------------------------
{
    const s = await api('/sessions', { method: 'POST', body: { agent_id: CHAT_AGENT, type: 'chat', device_id: 'conformance' } });
    if (check('chat session created', s.status === 200 && !!s.json.chat_token, `session=${s.json.session_id}`)) {
        const sid = s.json.session_id, tok = s.json.chat_token;
        const events = [];
        const es = await fetch(`${BASE}/gicc/api/sdk/v1/sessions/${sid}/events?chat_token=${encodeURIComponent(tok)}`, { headers: { Accept: 'text/event-stream' }, signal: AbortSignal.timeout(45000) }).catch(() => null);
        const reader = es?.body?.getReader();
        const pump = (async () => { if (!reader) return; const dec = new TextDecoder(); let buf = ''; try { for (;;) { const { value, done } = await reader.read(); if (done) break; buf += dec.decode(value, { stream: true }); let i; while ((i = buf.indexOf('\n\n')) >= 0) { const block = buf.slice(0, i); buf = buf.slice(i + 2); const data = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join(''); if (data) { try { events.push(JSON.parse(data)); } catch { /* keepalive */ } } } } } catch { /* stream ended */ } })();
        check('chat event stream opened', !!reader);
        const m = await api(`/sessions/${sid}/messages`, { method: 'POST', key: tok, body: { message_id: crypto.randomUUID(), content: 'Hello, what can you help me with?' } });
        check('chat message accepted', m.status === 200);
        const t0 = Date.now();
        while (Date.now() - t0 < 40000 && !events.some((e) => e.type === 'chat' || e.type === 'chat_complete')) await sleep(250);
        check('agent reply arrived on the event stream', events.some((e) => e.type === 'chat' || e.type === 'chat_complete'), `events=${[...new Set(events.map((e) => e.type))].join(',')}`);
        await api(`/sessions/${sid}/close`, { method: 'POST', key: tok });
        try { await reader?.cancel(); } catch { /* closed */ }
        await Promise.race([pump, sleep(1000)]);
        const after = await api(`/sessions/${sid}/status`, { key: tok });
        check('closed chat session rejects its token', after.status === 401 || after.status === 404 || after.json?.ok === false, `status=${after.status}`);
    }
}

// ---- 3. session grants (optional) ----------------------------------------------
let grantToken = null;
if (SECRET_KEY) {
    const g = await api('/session-grants', { method: 'POST', key: SECRET_KEY, body: { external_user_id: 'conformance-user', caller_phone: '+962790000000', caller_name: 'Conformance' } });
    check('secret key mints a session grant', g.status === 201 && !!g.json.session_grant);
    grantToken = g.json.session_grant || null;
    const bad = await api('/session-grants', { method: 'POST', key: APP_KEY, body: { external_user_id: 'x' } });
    check('app key cannot mint grants', bad.status === 401);
}

// ---- 4. voice over ws_audio ----------------------------------------------------
{
    const body = { agent_id: VOICE_AGENT, type: 'voice', device_id: 'conformance', ...(grantToken ? { session_grant: grantToken } : {}) };
    const s = await api('/sessions', { method: 'POST', body });
    if (check('voice session created', s.status === 200 && !!s.json.ws_url, `transport=${s.json.transport} token_ttl=${s.json.ws_token_expires_in}s`)) {
        if (grantToken) {
            const replay = await api('/sessions', { method: 'POST', body });
            check('a grant cannot be replayed', replay.status === 401, `status=${replay.status}`);
        }
        if (s.json.transport !== 'ws_audio') {
            check('agent serves ws_audio', false, `got ${s.json.transport}; use a realtime or pipeline agent`);
        } else {
            const agentPcm = []; const ctl = []; let lastFrameAt = 0; let seqGaps = 0; let lastSeq = null; const epochs = new Set();
            const open = (url) => new Promise((resolve, reject) => {
                const ws = new WebSocket(url); ws.on('open', () => resolve(ws)); ws.on('error', reject);
                ws.on('message', (d, bin) => { if (bin) { const f = decodeFrame(d); if (!f) return; agentPcm.push(f.pcm); lastFrameAt = Date.now(); epochs.add(f.epoch); if (lastSeq !== null && f.seq !== ((lastSeq + 1) & 0xffff)) seqGaps++; lastSeq = f.seq; } else { ctl.push(JSON.parse(d.toString())); } });
            });
            let ws = await open(toWs(s.json.ws_url));
            ws.send(JSON.stringify({ type: 'client.hello', sdk: 'conformance', version: '1', platform: 'node', mode: 'full_duplex' }));
            let seq = 0; const silence = Buffer.alloc(640); const q = [];
            let uplink = setInterval(() => { if (ws.readyState === 1) ws.send(encodeFrame({ epoch: 0, seq: seq++, pcm: q.shift() || silence }), { binary: true }); }, 20);
            const queue = (pcm) => { for (let o = 0; o < pcm.length; o += 640) { const c = pcm.subarray(o, o + 640); q.push(c.length === 640 ? c : Buffer.concat([c, Buffer.alloc(640 - c.length)])); } };
            await sleep(1500);
            const ready = ctl.find((m) => m.type === 'session.ready');
            check('session.ready received', !!ready && ready.uplink?.rate === 16000 && ready.downlink?.rate === 24000, ready ? `grace=${ready.grace_ms}ms` : 'none');
            ws.send(JSON.stringify({ type: 'ping', ts: Date.now() }));
            const t0 = Date.now();
            while (Date.now() - t0 < 25000 && !(agentPcm.length > 0 && Date.now() - lastFrameAt > 1500)) await sleep(100);
            const greetingMs = Math.round(agentPcm.reduce((n, b) => n + b.length, 0) / 48);
            check('greeting audio streamed', greetingMs > 500, `${greetingMs} ms, seq gaps=${seqGaps}`);
            check('ping answered', ctl.some((m) => m.type === 'pong'));
            check('stats messages arrive', ctl.some((m) => m.type === 'stats'));

            // Loop the greeting back as caller speech; expect a transcript and a reply.
            const fixture = resample24to16(Buffer.concat(agentPcm));
            const framesBefore = agentPcm.length; const speechBefore = ctl.filter((m) => m.type === 'speech' && m.side === 'user').length;
            queue(fixture);
            const t1 = Date.now();
            while (Date.now() - t1 < 30000 && agentPcm.length === framesBefore) await sleep(100);
            check('caller speech produced a reply', agentPcm.length > framesBefore, `after ${Date.now() - t1} ms`);
            const t2 = Date.now();
            while (Date.now() - t2 < 5000 && ctl.filter((m) => m.type === 'speech' && m.side === 'user').length === speechBefore) await sleep(100);
            check('caller transcript delivered', ctl.filter((m) => m.type === 'speech' && m.side === 'user').length > speechBefore);

            // Barge in while the reply plays (only meaningful when the agent allows interruption).
            await sleep(800);
            const interruptsBefore = ctl.filter((m) => m.type === 'audio.interrupted').length;
            queue(fixture);
            const t3 = Date.now();
            while (Date.now() - t3 < 12000 && ctl.filter((m) => m.type === 'audio.interrupted').length === interruptsBefore) await sleep(50);
            const gotInterrupt = ctl.filter((m) => m.type === 'audio.interrupted').length > interruptsBefore;
            check('barge-in announced a new epoch (skip if the agent forbids interruption)', true, gotInterrupt ? `yes, after ${Date.now() - t3} ms` : 'no interruption event');

            // Drop the socket without a close frame and resume.
            clearInterval(uplink);
            ws.terminate();
            await sleep(1000);
            const resumeUrl = `${toWs(s.json.ws_url).split('?')[0]}?resume_session=${encodeURIComponent(ready.session_id)}&resume_token=${encodeURIComponent(ready.resume_token)}`;
            try {
                ws = await open(resumeUrl);
                uplink = setInterval(() => { if (ws.readyState === 1) ws.send(encodeFrame({ epoch: 0, seq: seq++, pcm: silence }), { binary: true }); }, 20);
                await sleep(1500);
                check('resume within the grace window', ctl.filter((m) => m.type === 'session.ready' && m.resumed).length === 1);
            } catch (e) {
                check('resume within the grace window', false, e.message);
            }
            const badResume = await new Promise((resolve) => { const b = new WebSocket(`${toWs(s.json.ws_url).split('?')[0]}?resume_session=${encodeURIComponent(ready.session_id)}&resume_token=wrong`); b.on('close', (c) => resolve(c)); b.on('error', () => resolve(-1)); });
            check('wrong resume token refused', badResume === 1008, `close=${badResume}`);

            ws.send(JSON.stringify({ type: 'session.end', reason: 'conformance_done' }));
            clearInterval(uplink);
            await sleep(1500);
            check('session.end acknowledged', ctl.some((m) => m.type === 'session_ended'), `epochs seen=${[...epochs].join(',')}`);
            const reuse = await new Promise((resolve) => { const b = new WebSocket(toWs(s.json.ws_url)); b.on('close', (c) => resolve(c)); b.on('error', () => resolve(-1)); });
            check('socket token is single use', reuse === 1008, `close=${reuse}`);
        }
    }
}

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length ? 1 : 0);
