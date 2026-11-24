# Volai SDK contract changelog

Contract version is reported in `X-Volai-Contract` and in `GET /gicc/api/sdk/v1/health`. Server versions are the Volai releases that carry each change.

## Contract 1

| Server | Date | Change |
|---|---|---|
| v1.2.76 | 2026-10-09 | First release of `/gicc/api/sdk/v1`: agent lookup, sessions, chat over REST + SSE, OTP verification, session grants; `sdk` and `sdk_secret` keys; `ws_audio` voice transport for realtime-architecture agents (16 kHz up, 24 kHz down, 20 ms frames, epoch byte, 15 s reconnect grace); single-use 5-minute socket token |
| v1.2.77 | 2026-10-09 | Tenant setting for the browser default transport usable by platform administrators (no contract change) |
| v1.2.78 | 2026-10-09 | `ws_audio` for pipeline-architecture agents; every voice agent now advertises both transports |
| v1.2.79 | 2026-10-09 | Web-only hybrid for live-agent video (video-only WebRTC leg at `/gicc/ws/sdk/video`); native SDKs carry no video in contract 1 |
| next | 2026-10-30 | `caller_phone` on sessions and session grants is kept as sent (formatting stripped, `00` folded to `+`) instead of being rewritten to E.164; a national number such as `575104158` no longer becomes `+575104158`. Values that are not 7 to 15 digits with an optional `+`/`00` prefix are rejected with 400 (no contract change) |
| next | 2026-11-04 | `POST /sessions/{sessionId}/attachments` (multipart `file`, chat token): customer-side file upload, accepted only while a human agent owns the chat (409 `attachments_unavailable` before a transfer), 10 MB cap, same type allowlist as the agent desktop; the returned `attachment` goes unchanged into `messages`; `human_chat` / `chat` events carry `attachment` when the agent sends a file. SDKs: `uploadAttachment` / `sendAttachment` on every chat session (additive, contract stays 1) |
| next | 2026-11-10 | `POST /sessions/{sessionId}/attachments` accepts files at any point of the chat (no more 409 `attachments_unavailable` before a transfer). While the AI owns the chat the AI agent's Attachments setting answers: an automatic reply in the conversation language and, when configured, a transfer to a human agent (`LIVE_AGENT_CONNECTED` follows as usual); the file is shown to the agent with the transcript. No SDK change: `uploadAttachment` / `sendAttachment` simply work before a transfer |
| next | 2026-11-16 | `agentArchitecture` is no longer returned by the agent lookup (`GET /public/agent/{id}`, `/embed/config/{id}`); it described server internals and no SDK acted on it. SDK fields that read it (`architecture` / `agentArchitecture`) are now always empty (no contract change) |
| v1.4.16 | 2026-11-24 | Interactive messages: a chat session created with `capabilities: ["interactive"]` receives a question with options as an `interactive` event (`InteractiveMessage`: text, layout hint, 2 to 10 options, optional pictures) and answers it with `interaction_reply` on `messages`; `interactive_answered` follows the first answer. The app draws the options; the SDK only carries the payload. A session without the capability gets the same question as numbered text, so existing apps are unaffected. SDKs: `capabilities` on session creation, `reply(interactiveId, optionIds)` on the chat session (additive, contract stays 1) |
| v1.4.16 | 2026-11-24 | Forms: a chat session created with `capabilities: ["interactive", "forms"]` receives a form as an `interactive` event of kind `form` (`InteractiveForm`: fields in the conversation language, a prefill of what the agent knew) and answers with `interaction_reply.values` or `interaction_reply.cancelled`; a refused submit is 422 `invalid_form` with an error per field. Without `forms` the customer is asked one question per message as ordinary text, so existing apps are unaffected. SDKs: `'forms'` in `capabilities`, `submitForm(interactiveId, values)` and `cancelForm(interactiveId)` on the chat session (additive, contract stays 1) |
| v1.4.16 | 2026-11-24 | Cards: a chat session created with `cards` among its `capabilities` receives structured information as an `interactive` event of kind `card` (`InteractiveCard`: title, labelled values with optional progress, up to four actions, and the agent's `template` and `data` for an app's own card). An action is answered with `interaction_reply.option_ids`. Without `cards` the same content arrives as a question with options or as text. SDKs: `'cards'` in `capabilities`; `reply()` answers an action (additive, contract stays 1) |
| v1.4.18 | 2026-11-24 | Client actions: a chat session created with `client_actions` among its `capabilities` may receive a `client_action` event from a guided flow (`{ id, action, params, token, content }`): the app carries out the action in its own screens (a login, a payment) and gives `token` to its backend, which reports the result with the secret key at `POST /client-actions/complete` (`done`, `cancelled`, `failed`, optional `data`). The app may report only `cancelled` or `failed`, at `POST /sessions/{sessionId}/client-actions/{actionId}`. A session without the capability gets the step's text and link, so existing apps are unaffected (additive, contract stays 1) |
| v1.4.20 | 2026-11-25 | `language` on session creation: the language of the app's own screens (`ar`, `en`). When the agent allows it, the conversation is pinned to it from the start (greeting, replies, translated forms) instead of following the agent's default or being detected from the first messages; otherwise it is ignored. The call log shows the language source `client`. SDKs: `language` in `CreateSessionInput` (additive, contract stays 1) |

## Compatibility

| SDK package | Contract | Minimum server |
|---|---|---|
| `@volai/web-sdk` 0.1.x | 1 | v1.2.78 |
| all packages 0.2.x | 1 | v1.3.59 (chat attachments; earlier servers answer 404 on `uploadAttachment` / `sendAttachment`, everything else unchanged) |
| all packages 0.3.x | 1 | v1.4.20 for everything; v1.4.16 for options, forms and cards; v1.4.18 for client actions. An older server ignores `capabilities` and `language`, and the app gets plain text as before |

## SDK releases

| Tag | Date | Packages |
|---|---|---|
| v0.1.0 | 2026-10-10 | First release: iOS (Swift package), Android (Kotlin library), React Native, Flutter, web reference client, conformance tool. Contract 1. No live-agent video. |
| v0.1.1 | 2026-10-10 | `@volai/react-native-sdk` and `@volai/web-sdk` published to npm by the release workflow (trusted publishing). No code changes. |
| v0.1.2 | 2026-10-10 | npm only; the pub.dev job of this release did not complete. |
| v0.1.3 | 2026-10-10 | `volai_sdk` published to pub.dev and `com.globitel.volai:volai-sdk` to Maven Central by the release workflow. No code changes. |
| v0.2.0 | 2026-11-04 | `uploadAttachment` / `sendAttachment` and the `ChatAttachment` model on every chat session (web, iOS, Android, React Native, Flutter); conformance tool checks the attachment gate. Contract 1. |
| v0.2.1 | 2026-11-04 | Same code as v0.2.0; re-tagged so pub.dev publishes (its dry run needs the Flutter package changelog to list the version). |
| v0.3.0 | 2026-11-25 | Interactive messages on every chat session (web, iOS, Android, React Native, Flutter): `capabilities` on session creation, `reply`, `submitForm`, `cancelForm`, `reportClientAction`, and an error that carries a refused form's per-field messages. `language` on session creation. Attachments at any point of the chat. Web client: silent-microphone reporting (`micSilent`). Contract 1. |
