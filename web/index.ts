// @volai/web-sdk — reference browser client for the Volai SDK contract.
export { VolaiClient, VolaiChatSession, VolaiApiError } from './src/volaiClient';
export type { VolaiClientOptions, PublicAgent, CreateSessionInput, VoiceSessionInfo, ChatSessionInfo } from './src/volaiClient';
export { VolaiWsAudioClient } from './src/wsAudioClient';
export type { WsAudioClientOptions, WsAudioMode, WsAudioState, SessionReady } from './src/wsAudioClient';
export { encodeFrame, decodeFrame, FRAME_VERSION, HEADER_BYTES } from './src/wsAudioFrames';
export type { AudioFrame } from './src/wsAudioFrames';
export const SDK_CONTRACT_VERSION = 1;
