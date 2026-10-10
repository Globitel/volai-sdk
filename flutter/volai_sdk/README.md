# volai_sdk (Flutter)

Flutter client for the Volai SDK contract (contract 1): chat over REST and server-sent events, and voice as plain PCM over one WebSocket. It is a thin Dart layer over the native iOS and Android Volai libraries in this repository, vendored into the plugin by `scripts/sync-native.sh`. Flutter 3.10 or later, iOS 15, Android 7.0. No WebRTC.

## Install

```yaml
dependencies:
  volai_sdk:
    git:
      url: https://github.com/Globitel/volai-sdk.git
      ref: v0.1.0
      path: flutter/volai_sdk
```

Add `NSMicrophoneUsageDescription` to the iOS `Info.plist`; the Android manifest permission is declared by the plugin, request `RECORD_AUDIO` at runtime (for example with `permission_handler`) before a call.

## Use

```dart
import 'package:volai_sdk/volai_sdk.dart';

final volai = VolaiClient(baseUrl: 'https://gicc.globitel.com', appKey: '<publishable sdk key>');

// Chat
final chat = await volai.createChat(SessionRequest(agentId: '<public agent id>', deviceId: installId));
chat.events.listen((e) { if (e['type'] == 'chat') print(e['content']); });
await chat.start();
await chat.send('Hello');

// Voice
final call = await volai.createVoice(SessionRequest(agentId: '<public agent id>', deviceId: installId));
call.events.listen(print);
await call.connect();     // greeting starts; microphone frames flow once granted
await call.setMuted(true);
await call.end();
```

A session grant from your backend (minted with the secret key) goes in `sessionGrant` and makes the caller identity trusted. API errors surface as `VolaiException` with the server's `code`, `status` and `reason`.

## How it works

Audio capture, playback, barge-in, reconnect and the load-balancer affinity cookie are handled by the native libraries (see `ios/README.md` and `android/README.md` in the repository). The plugin exposes one method channel (`com.globitel.volai/sdk`) and one event channel (`com.globitel.volai/events`); `lib/volai_sdk.dart` routes events to the right session or call.

## Example app

`example/` is a Flutter app wired to this plugin: run it with `flutter run` after setting the base URL, app key and agent id in `lib/main.dart`.

Voice in the iOS simulator depends on the Mac's audio bridge; when it is wedged the app aborts in `AVAudioEngine.inputNode` about nine seconds after connecting (see `ios/README.md`). Test voice on a device, or on the Android emulator, when that happens.

## Not in contract 1

Live-agent video. Apps that need it keep the WebRTC transport outside this SDK.
