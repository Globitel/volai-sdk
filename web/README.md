# @volai/web-sdk

Reference browser client for the Volai SDK contract (contract 1): sessions,
chat over REST and server-sent events, and voice as plain PCM over one
WebSocket. It is the same code the Volai website widget uses, published so
native SDKs can mirror its behaviour. Contract: [`docs/openapi.yaml`](https://github.com/Globitel/volai-sdk/blob/main/docs/openapi.yaml)
and [`docs/voice-ws-protocol.md`](https://github.com/Globitel/volai-sdk/blob/main/docs/voice-ws-protocol.md) in this repository.
No WebRTC, no runtime dependencies.

## Install

```bash
npm install @volai/web-sdk
```

The package is an ES module with TypeScript declarations, for bundlers (Vite,
webpack, esbuild, Rollup) and for browsers that load modules directly. Without
a bundler, import it from an ESM CDN:

```html
<script type="module">
  import { VolaiClient } from 'https://cdn.jsdelivr.net/npm/@volai/web-sdk@0.2.1/+esm';
</script>
```

Every [GitHub release](https://github.com/Globitel/volai-sdk/releases) also
attaches `volai-web-sdk-<version>.tgz`, the built `dist/` folder, for
self-hosting.

Voice needs the microphone, so the page must be served over HTTPS (or from
`localhost`).

## Use

```ts
import { VolaiClient } from '@volai/web-sdk';

const volai = new VolaiClient({ baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>' });

// Chat
const chat = await volai.createChat({ agentId: '<public agent id>', deviceId: 'install-123' });
chat.onEvent((e) => { if (['chat', 'human_chat', 'system'].includes(String(e.type))) console.log('agent:', e.content); });
await chat.start();
await chat.send('Hello');
// Files, once a human agent has joined (LIVE_AGENT_CONNECTED): the AI does not read them
chat.onEvent((e) => { if (e.type === 'human_chat' && e.attachment) console.log('file from agent:', chat.attachmentUrl(e.attachment)); });
await chat.sendAttachment(fileInput.files[0]); // 409 attachments_unavailable before a transfer

// Voice (WebSocket audio: no WebRTC)
const { voice } = await volai.createVoice({ agentId: '<public agent id>', deviceId: 'install-123' });
voice.on('transcript', (t) => console.log(t));
voice.on('ended', (reason) => console.log('ended', reason));
await voice.connect();   // asks for the microphone; the greeting plays meanwhile
voice.setMuted(true);
voice.end();
```

A live agent's messages arrive as `human_chat`, and queue or hand-off status as `system`. An app that shows only `chat` goes silent after a hand-off.

A session grant from your backend (minted with the secret key) goes in
`sessionGrant` on `createChat` / `createVoice` and makes the caller identity
trusted.

## Build from source

```bash
cd web && npm ci && npm run build
```

Writes the ES module and type declarations to `web/dist`.
