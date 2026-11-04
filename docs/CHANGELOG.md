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

## Compatibility

| SDK package | Contract | Minimum server |
|---|---|---|
| `@volai/web-sdk` 0.1.x | 1 | v1.2.78 |
| all packages 0.2.x | 1 | v1.3.59 (chat attachments; earlier servers answer 404 on `uploadAttachment` / `sendAttachment`, everything else unchanged) |

## SDK releases

| Tag | Date | Packages |
|---|---|---|
| v0.1.0 | 2026-10-10 | First release: iOS (Swift package), Android (Kotlin library), React Native, Flutter, web reference client, conformance tool. Contract 1. No live-agent video. |
| v0.1.1 | 2026-10-10 | `@volai/react-native-sdk` and `@volai/web-sdk` published to npm by the release workflow (trusted publishing). No code changes. |
| v0.1.2 | 2026-10-10 | npm only; the pub.dev job of this release did not complete. |
| v0.1.3 | 2026-10-10 | `volai_sdk` published to pub.dev and `com.globitel.volai:volai-sdk` to Maven Central by the release workflow. No code changes. |
| v0.2.0 | 2026-11-04 | `uploadAttachment` / `sendAttachment` and the `ChatAttachment` model on every chat session (web, iOS, Android, React Native, Flutter); conformance tool checks the attachment gate. Contract 1. |
| v0.2.1 | 2026-11-04 | Same code as v0.2.0; re-tagged so pub.dev publishes (its dry run needs the Flutter package changelog to list the version). |
