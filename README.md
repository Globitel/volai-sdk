# Volai SDK

[![CI](https://github.com/Globitel/volai-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/Globitel/volai-sdk/actions/workflows/ci.yml)

Client SDKs for [Volai](https://gicc.globitel.com), Globitel's AI contact-center platform: hold a chat or a voice conversation with a Volai AI agent from your own app, with hand-off to a human agent when the AI decides so.

Voice runs as **plain PCM over one WebSocket**. No WebRTC, no media server library on the client.

| Platform | Folder | Status |
|---|---|---|
| Web (TypeScript) | [`web/`](web) | reference implementation, used by the Volai website widget |
| iOS (Swift, SPM) | [`ios/`](ios) | available: chat, voice, reconnect, half duplex; verified in the simulator |
| Android (Kotlin) | [`android/`](android) | available: chat, voice, reconnect, half duplex; verified in the emulator |
| React Native | [`react-native/`](react-native) | available: bridge over the native libraries, example app |
| Flutter | [`flutter/volai_sdk/`](flutter/volai_sdk) | available: plugin over the native libraries, example app |

The contract every SDK implements: [`docs/openapi.yaml`](docs/openapi.yaml) (REST) and [`docs/voice-ws-protocol.md`](docs/voice-ws-protocol.md) (voice socket). Changes by server release: [`docs/CHANGELOG.md`](docs/CHANGELOG.md).

## Credentials

Your Volai administrator creates two keys under General Settings, API keys:

- **App key** ships inside the app. It can look up agents, open sessions, chat, and run contact verification.
- **Secret key** stays on your backend and mints *session grants* that tell Volai who the app user is, so verified agents can skip the one-time code.

## Conformance

[`tools/conformance`](tools/conformance) drives the whole contract end to end against any Volai environment and prints a pass/fail report. Volai runs it against every server release; run it against your sandbox to see the expected behaviour of each step.

```bash
cd tools/conformance && npm install
node conformance.mjs --base https://gicc.globitel.com --app-key <app key> --secret-key <secret key> --voice-agent <public agent id>
```

## License

Apache 2.0. The SDKs are open; using them requires a Volai account.
