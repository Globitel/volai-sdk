# @volai/react-native-sdk

React Native client for the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. It is a thin JavaScript layer over the native iOS and Android Volai libraries in this repository, which are vendored into the package by `scripts/sync-native.sh`. React Native 0.71 or later, iOS 15, Android 7.0. No WebRTC.

## Install

```bash
npm install github:Globitel/volai-sdk#main --prefix . # or from npm once published
cd ios && pod install
```

Autolinking registers the module. Add `NSMicrophoneUsageDescription` to the iOS Info.plist; the Android manifest permission is declared by the library, request `RECORD_AUDIO` at runtime before a call.

## Use

```ts
import { VolaiClient } from '@volai/react-native-sdk';

const volai = new VolaiClient({ baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>' });

// Chat
const chat = await volai.createChat({ agentId: '<public agent id>', deviceId: installId });
chat.onEvent((e) => { if (e.type === 'chat') console.log(e.content); });
await chat.start();
await chat.send('Hello');

// Voice
const call = await volai.createVoice({ agentId: '<public agent id>', deviceId: installId });
call.onEvent((e) => console.log(e));
await call.connect();     // greeting starts; microphone frames flow once granted
await call.setMuted(true);
await call.end();
```

A session grant from your backend (minted with the secret key) goes in `sessionGrant` and makes the caller identity trusted.

## How it works

Audio capture, playback, barge-in, reconnect and the load-balancer affinity cookie are handled by the native libraries (see `ios/README.md` and `android/README.md` in the repository). Events reach JavaScript through `NativeEventEmitter` as `VolaiChatEvent` and `VolaiVoiceEvent`; the classes in `src/index.ts` route them to the right session or call.

## Example app

`example/` is a React Native app wired to this package: run it with `npx react-native run-ios` or `run-android` after setting the base URL, app key and agent id in `App.tsx`.

Voice in the iOS simulator depends on the Mac's audio bridge; when it is wedged the app aborts in `AVAudioEngine.inputNode` about nine seconds after connecting (see `ios/README.md`). Test voice on a device, or on the Android emulator, when that happens.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
