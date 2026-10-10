# Volai voice socket protocol

Contract 1 (2026-10-08). Companion to `openapi.yaml`. Read `voiceTransports` on the agent and `transport` on the session response; never assume a transport.

## Transport `webrtc` (available now)

Signalling socket: the `ws_url` from `POST /sessions` (`wss://<host>/gicc/ws/client?ws-token=...`). The token is single use and expires after `ws_token_expires_in` seconds. Media is WebRTC through mediasoup, so the client needs a mediasoup-client library for its platform (iOS, Android, React Native, Flutter ports exist). Plain RTCPeerConnection offer/answer is not accepted.

Text frames are JSON. Sequence:

| Step | Client sends | Server answers |
|---|---|---|
| 1 | `{ "type": "getRouterRtpCapabilities" }` | `{ "type": "routerRtpCapabilities", "routerRtpCapabilities": {...} }` |
| 2 | `{ "type": "createWebRtcTransport", "id": 2 }` (send) | `{ "type": "webRtcTransportCreated", "id": 2, "transportId", "iceParameters", "iceCandidates", "dtlsParameters" }` |
| 3 | `{ "type": "connectWebRtcTransport", "id": 2, "dtlsParameters": {...} }` | no reply |
| 4 | `{ "type": "produce", "kind": "audio", "rtpParameters": {...} }` | `{ "type": "produced", "id": "<producerId>" }` |
| 5 | `{ "type": "createWebRtcTransport", "id": 3 }` (receive) | `webRtcTransportCreated` with `id: 3` |
| 6 | `{ "type": "connectWebRtcTransport", "id": 3, "dtlsParameters": {...} }` | no reply |
| 7 | `{ "type": "consume", "rtpCapabilities": {...} }` | `{ "type": "consumed", "id", "producerId", "kind", "rtpParameters" }` |
| 8 | `{ "type": "resume" }` after the consumer is created | the agent greeting starts |

Server events during the call:

| Type | Payload | Meaning |
|---|---|---|
| `speech` | `{ role: "user", content }` | Caller transcript |
| `chunk` | `{ role: "agent", content }` | Agent transcript fragment |
| `speakStart` / `speakEnd` | | Agent started or stopped speaking |
| `switchAudioSource` | `{ consumerId, producerId, kind, rtpParameters }` | Live agent took over; consume the new producer |
| `system` | `{ content }` | System notice |
| `context_update` | `{ context }` | Session context changed |
| `error` | `{ message }` | Recoverable error |
| `fatal_error` | `{ code, message }` | End the call |
| `SESSION_ENDED` (also `session_ended`) | `{ reason? }` | Call ended by the server |

Mute is client side (stop the track or send silence). Hang up by closing the socket; the server closes the session and writes the call log.

Audio: Opus 48 kHz via WebRTC. Echo cancellation comes from the platform's voice-chat audio mode and must be enabled.

## Transport `ws_audio` (available, default for SDK sessions)

One socket per call, the `ws_url` from `POST /sessions` (`wss://<host>/gicc/ws/sdk/voice?token=...`), carrying JSON control frames (text) and raw PCM frames (binary). No WebRTC or mediasoup on the client. Both agent architectures serve it. The session response says `"transport": "ws_audio"`; always read `voiceTransports` on the agent and `transport` on the session rather than assume.

### Binary frames (both directions)

| Byte | Field |
|---|---|
| 0 | version, `1` |
| 1 | playback epoch on downlink frames, `0` on uplink |
| 2-3 | uint16 big-endian sequence number, wraps |
| 4.. | PCM16 little-endian mono |

Uplink: 16 kHz, 20 ms frames (640 bytes of PCM). Downlink: 24 kHz, 20 ms frames (960 bytes of PCM). `session.ready` carries the exact values; honour them rather than hard-coding. The server sends no frame while the agent is silent, so a client plays what it has and pads with silence when its buffer is empty. Keep a jitter buffer of 100 to 300 ms.

### Call sequence

1. Connect. The server answers with `session.ready` once the AI session is up.
2. Send `client.hello`. The greeting starts when the server has seen `client.hello` or the first uplink frame, whichever comes first.
3. Stream uplink frames continuously, including while the agent speaks (full duplex). Echo cancellation is the device's job: iOS play-and-record in voice-chat mode, Android `VOICE_COMMUNICATION`. Devices without usable echo cancellation send `mode: "half_duplex"` in `client.hello`; the server then ignores uplink audio while the agent speaks, which disables barge-in.
4. Play downlink frames in sequence order. On `audio.interrupted`, drop every buffered frame whose epoch is older than the announced one.
5. Hang up with `session.end`, or just close the socket with code 1000.

### Client to server control messages

| Type | Fields | Meaning |
|---|---|---|
| `client.hello` | `sdk`, `version`, `platform`, `mode` (`full_duplex` default, or `half_duplex`) | First message after connect |
| `mic.muted` | `muted` | Uplink is ignored while muted; the server feeds the agent silence at the frame cadence instead, so a turn that ended just before muting is still detected and answered |
| `playback.flushed` | `epoch` | Optional: client finished dropping an older epoch |
| `ping` | `ts` | Answered with `pong` |
| `stats` | `rtt_ms` | Optional client measurements |
| `session.end` | `reason` | Caller hung up |

### Server to client control messages

| Type | Fields | Meaning |
|---|---|---|
| `session.ready` | `session_id`, `contract`, `uplink` `{rate, frame_ms, bytes, encoding}`, `downlink` `{...}`, `epoch`, `resume_token`, `grace_ms`, `mode`, `resumed?` | Audio may start |
| `audio.interrupted` | `epoch`, `reason` (`speaking_pause`, `backend_interrupted`, `human_takeover`, `resume`) | Barge-in or reset: drop frames older than `epoch` |
| `speakStart` / `speakEnd` | | Agent started or stopped speaking |
| `speech` | `side` (`user` or `assistant`), `utterance` | Transcripts |
| `chunk` | `role`, `content` | Agent transcript fragment (text models) |
| `system` | `content` | System notice, including live-agent queue texts |
| `context_update` | `context` | Session context changed |
| `LIVE_AGENT_CONNECTED` / `LIVE_AGENT_DISCONNECTED` | | Human agent joined or left |
| `stats` | `epoch`, `uplink_frames`, `uplink_dropped`, `downlink_frames`, `downlink_dropped`, `downlink_buffered_ms`, `reconnects` | Every 5 seconds |
| `pong` | `ts`, `server_ts` | |
| `session_ended` | `reason` | Server ended the call; the socket closes right after |
| `error` | `code`, `message`, `fatal` | |

### Reconnect within a call

If the socket drops without a clean close (network switch, app backgrounded) the server keeps the call alive for `grace_ms` (15 seconds by default) with playback paused. Reconnect to `wss://<host>/gicc/ws/sdk/voice?resume_session=<session_id>&resume_token=<resume_token>`; the server answers `audio.interrupted` with a new epoch and `session.ready` with `resumed: true`, and audio continues. A wrong or late resume is refused with close code 1008. The reconnect must reach the same server node; the load balancer pins on the session id.

### Video with a live agent

Contract 1 carries no video on the ws_audio socket. Live-agent video (the caller's camera to the agent desktop and the agent's camera back) is a WebRTC feature:

- **Web clients** keep it through a hybrid: while audio stays on the ws_audio socket, the page opens a second, video-only WebRTC signalling socket at `wss://<host>/gicc/ws/sdk/video?video_session=<session_id>&video_token=<resume_token>` when the server announces `agentVideoAvailable` or `liveAgentVideoEnabled` on the audio socket. The server answers `video.ready`; the page then runs the normal mediasoup handshake on that socket (`getRouterRtpCapabilities`, `createWebRtcTransport`, `connectWebRtcTransport`, `produce` with `kind: "video"`, `consumeAgentVideo`, `resumeVideo`). Audio `produce` and `consume` are refused on it with `code: "video_only"`. The Volai embed widget and portal tester implement this.
- **Native SDKs** should not implement video in contract 1. Live-agent video on mobile is planned as a later contract on a transport with native SDKs on every platform; until then, apps that must show agent video can stay on the `webrtc` transport.

### Backpressure

If the client falls more than 400 ms behind (socket buffer), the server drops downlink frames and counts them in `stats.downlink_dropped`. Uplink frames received before the ingest pipeline is ready are buffered for up to two seconds.
