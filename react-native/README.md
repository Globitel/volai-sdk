# @volai/react-native-sdk

React Native client for the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. It is a thin JavaScript layer over the native iOS and Android Volai libraries in this repository, which are vendored into the package by `scripts/sync-native.sh`. React Native 0.71 or later, iOS 15, Android 7.0. No WebRTC.

## Install

```bash
npm install @volai/react-native-sdk
cd ios && pod install
```

Autolinking registers the module. Add `NSMicrophoneUsageDescription` to the iOS Info.plist; the Android manifest permission is declared by the library, request `RECORD_AUDIO` at runtime before a call.

## Use

```ts
import { VolaiClient } from '@volai/react-native-sdk';

const volai = new VolaiClient({ baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>' });

// Chat
const chat = await volai.createChat({ agentId: '<public agent id>', deviceId: installId });
chat.onEvent((e) => { if (['chat', 'human_chat', 'system'].includes(String(e.type))) console.log(e.content); });
await chat.start();
await chat.send('Hello');
// Files, at any point of the chat: a human agent receives them; before a transfer the AI agent's Attachments setting answers
await chat.sendAttachment({ path: 'file:///…/invoice.pdf' });

// Voice
const call = await volai.createVoice({ agentId: '<public agent id>', deviceId: installId });
call.onEvent((e) => console.log(e));
await call.connect();     // greeting starts; microphone frames flow once granted
await call.setMuted(true);
await call.end();
```

A live agent's messages arrive as `human_chat`, and queue or hand-off status as `system`. An app that shows only `chat` goes silent after a hand-off.

A session grant from your backend (minted with the secret key) goes in `sessionGrant` and makes the caller identity trusted.

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
// A refused form: catch (err) { if (err instanceof VolaiFormError) show(err.errors) }
```

## How it works

Audio capture, playback, barge-in, reconnect and the load-balancer affinity cookie are handled by the native libraries (see `ios/README.md` and `android/README.md` in the repository). Events reach JavaScript through `NativeEventEmitter` as `VolaiChatEvent` and `VolaiVoiceEvent`; the classes in `src/index.ts` route them to the right session or call.

## Example app

`example/` is a React Native app wired to this package: run it with `npx react-native run-ios` or `run-android` after setting the base URL, app key and agent id in `App.tsx`.

Voice in the iOS simulator depends on the Mac's audio bridge; when it is wedged the app aborts in `AVAudioEngine.inputNode` about nine seconds after connecting (see `ios/README.md`). Test voice on a device, or on the Android emulator, when that happens.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
