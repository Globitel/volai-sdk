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
Task { for await event in chat.events { if event.string("type") == "chat" { print(event.string("content") ?? "") } } }
try await chat.send("Hello")

// Voice
let call = try await volai.createVoice(SessionRequest(agentId: "<public agent id>", deviceId: installId))
Task { for await event in call.events { print(event) } }
try await call.connect()          // greeting starts; the microphone is captured once granted
call.setMuted(true)
call.end()
```

A session grant from your backend (minted with the secret key) goes in `SessionRequest.sessionGrant` and makes the caller identity trusted.

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
