# volai_sdk (Flutter)

Flutter client for the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. It is a thin Dart layer over the native iOS and Android Volai libraries in this repository, vendored into the plugin by `scripts/sync-native.sh`. Flutter 3.10 or later, iOS 15, Android 7.0. No WebRTC.

## Install

```yaml
dependencies:
  volai_sdk: ^0.3.0
```

Or straight from the repository: `git: { url: https://github.com/Globitel/volai-sdk.git, ref: v0.3.0, path: flutter/volai_sdk }`.

Add `NSMicrophoneUsageDescription` to the iOS `Info.plist`; the Android manifest permission is declared by the plugin, request `RECORD_AUDIO` at runtime (for example with `permission_handler`) before a call.

## Use

```dart
import 'package:volai_sdk/volai_sdk.dart';

final volai = VolaiClient(baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>');

// Chat
final chat = await volai.createChat(SessionRequest(agentId: '<public agent id>', deviceId: installId));
chat.events.listen((e) { if (const {'chat', 'human_chat', 'system'}.contains(e['type'])) print(e['content']); });
await chat.start();
await chat.send('Hello');
// Files, at any point of the chat: a human agent receives them; before a transfer the AI agent's Attachments setting answers
await chat.sendAttachment('/path/to/invoice.pdf');

// Voice
final call = await volai.createVoice(SessionRequest(agentId: '<public agent id>', deviceId: installId));
call.events.listen(print);
await call.connect();     // greeting starts; microphone frames flow once granted
await call.setMuted(true);
await call.end();
```

A live agent's messages arrive as `human_chat`, and queue or hand-off status as `system`. An app that shows only `chat` goes silent after a hand-off.

A session grant from your backend (minted with the secret key) goes in `sessionGrant` and makes the caller identity trusted. API errors surface as `VolaiException` with the server's `code`, `status` and `reason`.

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

The shapes are in [`docs/openapi.yaml`](https://github.com/Globitel/volai-sdk/blob/main/docs/openapi.yaml) (`InteractiveMessage`, `InteractiveForm`, `InteractiveCard`). Needs Volai v1.4.20.

```dart
final chat = await volai.createChat(SessionRequest(agentId: agentId, deviceId: deviceId,
    capabilities: ['interactive', 'forms', 'cards', 'client_actions'], language: 'ar'));
chat.events.listen((e) async {
  if (e['type'] == 'interactive') {
    final item = Map<String, dynamic>.from(e['interactive'] as Map);
    final id = item['id'] as String;
    if (item['kind'] == 'form') {
      showForm(item);        // then: await chat.submitForm(id, {'email': 'a@b.co'})
    } else if (item['kind'] == 'card') {
      showCard(item);        // an action: await chat.reply(id, [actionId])
    } else {
      showOptions(item);     // then: await chat.reply(id, [optionId])
    }
  }
  if (e['type'] == 'interactive_answered') lock(e['id']);
  if (e['type'] == 'client_action') {
    // run your own screen, hand e['token'] to your backend;
    // the customer backed out: await chat.reportClientAction(e['id'] as String, 'cancelled')
  }
});
// A refused form: on VolaiFormException catch (err) { show(err.errors); }
```

## How it works

Audio capture, playback, barge-in, reconnect and the load-balancer affinity cookie are handled by the native libraries (see `ios/README.md` and `android/README.md` in the repository). The plugin exposes one method channel (`com.globitel.volai/sdk`) and one event channel (`com.globitel.volai/events`); `lib/volai_sdk.dart` routes events to the right session or call.

## Example app

`example/` is a Flutter app wired to this plugin: run it with `flutter run` after setting the base URL, app key and agent id in `lib/main.dart`.

Voice in the iOS simulator depends on the Mac's audio bridge; when it is wedged the app aborts in `AVAudioEngine.inputNode` about nine seconds after connecting (see `ios/README.md`). Test voice on a device, or on the Android emulator, when that happens.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
