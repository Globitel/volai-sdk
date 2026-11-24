# VolaiSDK for iOS

Swift package implementing the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. iOS 15 or later. No WebRTC.

## Install

Swift Package Manager, from the repository root manifest (releases are tagged `vX.Y.Z`):

```swift
.package(url: "https://github.com/Globitel/volai-sdk", from: "0.1.0")
```

Add the `VolaiSDK` product to your target. Add `NSMicrophoneUsageDescription` to your app's Info.plist for voice.

## Use

```swift
import VolaiSDK

let volai = VolaiClient(baseURL: URL(string: "https://gicc.globitel.com")!, appKey: "<publishable sdk key>")

// Chat
let chat = try await volai.createChat(SessionRequest(agentId: "<public agent id>", deviceId: installId))
chat.start()
Task { for await event in chat.events { if ["chat", "human_chat", "system"].contains(event.string("type")) { print(event.string("content") ?? "") } } }
try await chat.send("Hello")
// Files, at any point of the chat: a human agent receives them; before a transfer the AI agent's Attachments setting answers
try await chat.sendAttachment(pdfData, filename: "invoice.pdf", mimeType: "application/pdf")
// A file from the agent arrives as a human_chat event: ChatAttachment(json: event.object("attachment")), chat.attachmentURL(_:)

// Voice
let call = try await volai.createVoice(SessionRequest(agentId: "<public agent id>", deviceId: installId))
Task { for await event in call.events { print(event) } }
try await call.connect()          // greeting starts; the microphone is captured once granted
call.setMuted(true)
call.end()
```

A live agent's messages arrive as `human_chat`, and queue or hand-off status as `system`. An app that shows only `chat` goes silent after a hand-off.

A session grant from your backend (minted with the secret key) goes in `SessionRequest.sessionGrant` and makes the caller identity trusted.

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

```swift
let chat = try await volai.createChat(SessionRequest(agentId: "<public agent id>", deviceId: installId,
                                                     capabilities: ["interactive", "forms", "cards", "client_actions"], language: "ar"))
for await event in chat.events {
    switch event.string("type") {
    case "interactive":
        guard let item = event.object("interactive"), let id = item.string("id") else { break }
        switch item.string("kind") {
        case "form": showForm(item)        // then: try await chat.submitForm(interactiveId: id, values: ["email": "a@b.co"])
        case "card": showCard(item)        // an action: try await chat.reply(interactiveId: id, optionIds: [actionId])
        default: showOptions(item)         // then: try await chat.reply(interactiveId: id, optionIds: [optionId])
        }
    case "interactive_answered": lock(event.string("id"))
    case "client_action":                  // run your own screen, hand event.string("token") to your backend
        // the customer backed out: try await chat.reportClientAction(actionId: event.string("id")!, outcome: "cancelled")
        break
    default: break
    }
}
// A refused form: catch VolaiError.invalidForm(let errors, _) and show errors[fieldKey]
```

## What the package does for you

- Audio session in play-and-record, voice-chat mode, which gives hardware echo cancellation; capture resampled to 16 kHz in 20 ms frames, playback from a jitter buffer at the device's output rate.
- Barge-in: `audio.interrupted` flushes the playback buffer by epoch, so the agent stops within one frame.
- Reconnect: an abnormal socket loss resumes the call within the server's grace window with the resume token; a clean close ends it.
- Load-balancer affinity: `URLSession` cookie storage keeps the production routing cookie across the REST calls, the voice socket and reconnects.
- Half duplex: `createVoice(..., mode: .halfDuplex)` for devices without usable echo cancellation (no barge-in).

## Tests

```bash
swift test                                   # protocol, buffer, resampler and model tests
# live tests against a Volai environment (skipped without these variables):
VOLAI_BASE_URL=https://gicc.globitel.com VOLAI_APP_KEY=... VOLAI_AGENT=... swift test --filter LiveTests
# on the simulator:
xcodebuild test -scheme VolaiSDK -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`VOLAI_WS_BASE=ws://localhost:8085` rewrites the socket origin for a development stack whose WebSocket server runs on another port. Under `xcodebuild`, prefix the variables with `TEST_RUNNER_`.

The simulator routes audio through the Mac's audio daemon. If the voice test (or any app using the SDK) aborts about nine seconds after `connect()` with `AURemoteIO::Cleanup ... RPC timeout. Apparently deadlocked` in `-[AVAudioEngine inputNode]`, the simulator's audio bridge on that Mac is wedged, not the SDK: the same build runs on macOS (`swift test`) and on a device. Restarting CoreSimulator or the Mac clears it.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
