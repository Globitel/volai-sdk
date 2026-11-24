# VolaiSDK for Android

Kotlin library implementing the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. Android 7.0 (API 24) or later. No WebRTC.

## Install

From Maven Central:

```kotlin
dependencies { implementation("com.globitel.volai:volai-sdk:0.3.0") }
```

The AAR is also attached to each [GitHub release](https://github.com/Globitel/volai-sdk/releases) for apps that vendor libraries; it needs `com.squareup.okhttp3:okhttp:4.12.0` and `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0` alongside. A checkout can also be included with `includeBuild("path/to/volai-sdk/android")`.

Add `RECORD_AUDIO` to your manifest (the library declares it) and request it at runtime before starting a voice call.

## Use

```kotlin
import com.globitel.volai.*

val volai = VolaiClient(baseUrl = "https://gicc.globitel.com", appKey = "<publishable sdk key>")

// Chat
val chat = volai.createChat(SessionRequest(agentId = "<public agent id>", deviceId = installId))
chat.start()
scope.launch { chat.events.collect { if (it.optString("type") in setOf("chat", "human_chat", "system")) println(it.optString("content")) } }
chat.send("Hello")
// Files, at any point of the chat: a human agent receives them; before a transfer the AI agent's Attachments setting answers
chat.sendAttachment(File(cacheDir, "invoice.pdf"))
// A file from the agent arrives as a human_chat event: ChatAttachment.fromJson(event.optJSONObject("attachment")), chat.attachmentUrl(it)

// Voice
val call = volai.createVoice(SessionRequest(agentId = "<public agent id>", deviceId = installId))
scope.launch { call.events.collect { println(it) } }
call.connect(context)      // greeting starts; microphone frames flow once granted
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

```kotlin
val chat = volai.createChat(SessionRequest(agentId = "<public agent id>", deviceId = installId,
    capabilities = listOf("interactive", "forms", "cards", "client_actions"), language = "ar"))
chat.events.collect { event ->
    when (event.optString("type")) {
        "interactive" -> {
            val item = event.getJSONObject("interactive"); val id = item.getString("id")
            when (item.optString("kind")) {
                "form" -> showForm(item)      // then: chat.submitForm(id, mapOf("email" to "a@b.co"))
                "card" -> showCard(item)      // an action: chat.reply(id, listOf(actionId))
                else -> showOptions(item)     // then: chat.reply(id, listOf(optionId))
            }
        }
        "interactive_answered" -> lock(event.optString("id"))
        "client_action" -> { /* run your own screen, hand event.getString("token") to your backend;
                                the customer backed out: chat.reportClientAction(event.getString("id"), "cancelled") */ }
    }
}
// A refused form: catch (e: VolaiException.InvalidForm) and show e.errors[fieldKey]
```

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
