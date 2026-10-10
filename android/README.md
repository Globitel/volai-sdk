# VolaiSDK for Android

Kotlin library implementing the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. Android 7.0 (API 24) or later. No WebRTC.

## Install

Until the package is on Maven Central, take the AAR from the [GitHub release](https://github.com/Globitel/volai-sdk/releases) (`volai-android-sdk-vX.Y.Z.aar`) and add its two runtime dependencies:

```kotlin
// build.gradle.kts of your app
dependencies {
    implementation(files("libs/volai-android-sdk-v0.1.2.aar"))
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
```

Or include the module from a checkout: `includeBuild("path/to/volai-sdk/android")` in `settings.gradle.kts` and `implementation("com.globitel.volai:volai-sdk:0.1.2")`.

Add `RECORD_AUDIO` to your manifest (the library declares it) and request it at runtime before starting a voice call.

## Use

```kotlin
import com.globitel.volai.*

val volai = VolaiClient(baseUrl = "https://gicc.globitel.com", appKey = "<publishable sdk key>")

// Chat
val chat = volai.createChat(SessionRequest(agentId = "<public agent id>", deviceId = installId))
chat.start()
scope.launch { chat.events.collect { if (it.optString("type") == "chat") println(it.optString("content")) } }
chat.send("Hello")

// Voice
val call = volai.createVoice(SessionRequest(agentId = "<public agent id>", deviceId = installId))
scope.launch { call.events.collect { println(it) } }
call.connect(context)      // greeting starts; microphone frames flow once granted
call.setMuted(true)
call.end()
```

A session grant from your backend (minted with the secret key) goes in `SessionRequest.sessionGrant` and makes the caller identity trusted.

## What the library does for you

- `AudioRecord` on the `VOICE_COMMUNICATION` source at 16 kHz in 20 ms frames with the platform echo canceller and noise suppressor when available; `AudioTrack` playback at 24 kHz from a jitter buffer; `MODE_IN_COMMUNICATION` for the duration of the call.
- Barge-in: `audio.interrupted` flushes the playback buffer by epoch, so the agent stops within one frame.
- Reconnect: an abnormal socket loss resumes the call within the server's grace window with the resume token; a clean close ends it.
- Load-balancer affinity: one `OkHttpClient` with a cookie jar serves REST, the event stream and the voice socket, so the production routing cookie travels with every connection.
- Half duplex: `createVoice(..., mode = VoiceCall.Mode.HALF_DUPLEX)` for devices without usable echo cancellation (no barge-in).

## Tests

```bash
./gradlew :volai-sdk:testDebugUnitTest          # protocol, buffer, SSE parser and model tests
# live tests on a device or emulator against a Volai environment (skipped without the arguments):
./gradlew :volai-sdk:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.volaiBaseUrl=https://gicc.globitel.com \
  -Pandroid.testInstrumentationRunnerArguments.volaiAppKey=... \
  -Pandroid.testInstrumentationRunnerArguments.volaiAgent=...
```

On a development stack use `volaiBaseUrl=http://10.0.2.2:3007` and `volaiWsBase=ws://10.0.2.2:8085` from the emulator.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
