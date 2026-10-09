# @volai/web-sdk

Reference browser client for the Volai SDK contract (contract 1). It is the
same code the Volai website widget uses, published so native SDKs can mirror
its behaviour. Contract: `docs/sdk/openapi.yaml` and
`docs/sdk/voice-ws-protocol.md` in the Volai repository.

```ts
import { VolaiClient } from '@volai/web-sdk';

const volai = new VolaiClient({ baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>' });

// Chat
const chat = await volai.createChat({ agentId: '<public agent id>', deviceId: 'install-123' });
chat.onEvent((e) => { if (e.type === 'chat') console.log('agent:', e.content); });
await chat.start();
await chat.send('Hello');

// Voice (WebSocket audio: no WebRTC)
const { voice } = await volai.createVoice({ agentId: '<public agent id>', deviceId: 'install-123' });
voice.on('transcript', (t) => console.log(t));
voice.on('ended', (reason) => console.log('ended', reason));
await voice.connect();   // asks for the microphone; the greeting plays meanwhile
voice.setMuted(true);
voice.end();
```

A session grant from your backend (minted with the secret key) goes in
`sessionGrant` on `createChat` / `createVoice` and makes the caller identity
trusted.

Build from the repository root: `npm run sdk:build` (ES module + type
declarations in `sdk/web/dist`).
