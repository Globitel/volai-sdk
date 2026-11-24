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
  import { VolaiClient } from 'https://cdn.jsdelivr.net/npm/@volai/web-sdk@0.3.0/+esm';
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
// Files, at any point of the chat: a human agent receives them; before a transfer the AI agent's Attachments setting answers
chat.onEvent((e) => { if (e.type === 'human_chat' && e.attachment) console.log('file from agent:', chat.attachmentUrl(e.attachment)); });
await chat.sendAttachment(fileInput.files[0]);

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

## Buttons, forms, cards and app steps

A Volai agent can send more than text: a question with options, a form, a card, or a step your app carries out itself (a login, a payment). The SDK carries these; **your app draws them**. Ask for what you draw with `capabilities` when you create the chat. Anything you do not ask for arrives as ordinary text, so an app that sets nothing keeps working.

| Capability | Event | What to draw | How to answer |
|---|---|---|---|
| `interactive` | `interactive`, kind `choices` | The question and its options (`layout` hints buttons, a list, or picture cards) | `reply` with the option ids |
| `forms` | `interactive`, kind `form` | The form's fields, with `prefill` | `submitForm`, or `cancelForm` |
| `cards` | `interactive`, kind `card` | Labelled values and up to four actions; `template` and `data` name a card of your own | `reply` with the action id |
| `client_actions` | `client_action` | Your own screen for `action`, with `params` | Your backend reports the result; the app may report `cancelled` or `failed` |

- `interactive_answered` follows the first answer, also when the customer typed it: lock what you drew.
- A refused form comes back with one message per field. Keep the form open and show them.
- For a `client_action`, give `token` to your backend. Only the backend, with the secret key, can say the step was done (`POST /client-actions/complete`). The flow's next message arrives as a normal event.
- `language` (`ar`, `en`) is the language of your app's screens. When the agent allows it, the chat opens and stays in it. It is read once, at session creation.

The shapes are in [`docs/openapi.yaml`](../docs/openapi.yaml) (`InteractiveMessage`, `InteractiveForm`, `InteractiveCard`). Needs Volai v1.4.20.

```ts
const chat = await volai.createChat({ agentId, deviceId, capabilities: ['interactive', 'forms', 'cards', 'client_actions'], language: 'ar' });
chat.onEvent(async (e) => {
  if (e.type === 'interactive') {
    const item = e.interactive as InteractiveMessage | InteractiveForm | InteractiveCard;
    if (item.kind === 'form') showForm(item);        // then: await chat.submitForm(item.id, { email: 'a@b.co' })
    else if (item.kind === 'card') showCard(item);   // an action: await chat.reply(item.id, [actionId])
    else showOptions(item);                          // then: await chat.reply(item.id, [optionId])
  }
  if (e.type === 'interactive_answered') lock(e.id);
  if (e.type === 'client_action') {
    // run your own screen, hand e.token to your backend;
    // the customer backed out: await chat.reportClientAction(e.id as string, 'cancelled')
  }
});
// A refused form: VolaiApiError with status 422, body.reason 'invalid_form' and body.errors by field key
```

## Build from source

```bash
cd web && npm ci && npm run build
```

Writes the ES module and type declarations to `web/dist`.
