# Volai SDK contract changelog

Contract version is reported in `X-Volai-Contract` and in `GET /gicc/api/sdk/v1/health`. Server versions are the Volai releases that carry each change.

## Contract 1

| Server | Date | Change |
|---|---|---|
| v1.2.76 | 2026-10-09 | First release of `/gicc/api/sdk/v1`: agent lookup, sessions, chat over REST + SSE, OTP verification, session grants; `sdk` and `sdk_secret` keys; `ws_audio` voice transport for realtime-architecture agents (16 kHz up, 24 kHz down, 20 ms frames, epoch byte, 15 s reconnect grace); single-use 5-minute socket token |
| v1.2.77 | 2026-10-09 | Tenant setting for the browser default transport usable by platform administrators (no contract change) |
| v1.2.78 | 2026-10-09 | `ws_audio` for pipeline-architecture agents; every voice agent now advertises both transports |
| v1.2.79 | 2026-10-09 | Web-only hybrid for live-agent video (video-only WebRTC leg at `/gicc/ws/sdk/video`); native SDKs carry no video in contract 1 |

## Compatibility

| SDK package | Contract | Minimum server |
|---|---|---|
| `@volai/web-sdk` 0.1.x | 1 | v1.2.78 |
