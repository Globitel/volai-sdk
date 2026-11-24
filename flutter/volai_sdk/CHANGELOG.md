## 0.3.0

- `capabilities` on `SessionRequest`: the app says what it draws itself (`interactive`, `forms`, `cards`, `client_actions`) and receives questions with options, forms, cards and app steps as events instead of plain text.
- `reply`, `submitForm`, `cancelForm` and `reportClientAction` on `VolaiChatSession`; `VolaiFormException` carries the per-field messages of a refused form.
- `language` on `SessionRequest`: the chat opens and stays in the language of the app's screens when the agent allows it.
- Attachments can be sent at any point of the chat, not only after a hand-off.
- Needs Volai v1.4.20 for all of the above; older servers ignore the new fields. Contract 1.

## 0.2.1

- Re-release of 0.2.0 for pub.dev (its publish needs this file to mention the version). No code changes.

## 0.2.0

- `uploadAttachment` and `sendAttachment` on `VolaiChatSession`, plus `ChatAttachment` (`ChatAttachment.fromEvent` for files the human agent sends). Uploads are accepted once a human agent owns the chat; before a transfer the server answers 409 `attachments_unavailable`. Needs Volai v1.3.59. Contract 1.

## 0.1.3

- Published by the release workflow (pub.dev automated publishing). No code changes.

## 0.1.2

- Version bump only; not published to pub.dev.

## 0.1.1

- First release on pub.dev. Chat over REST and server-sent events; voice as PCM over one WebSocket (16 kHz up, 24 kHz down), barge-in, reconnect, half duplex. Bridges the native iOS and Android Volai libraries. Contract 1; no live-agent video.
