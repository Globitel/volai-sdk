// Binary frame codec for the ws_audio voice transport. Mirrors
// agent/lib/ws_audio_frames.js and docs/sdk/voice-ws-protocol.md.
export const FRAME_VERSION = 1;
export const HEADER_BYTES = 4;

export interface AudioFrame {
  version: number;
  epoch: number;
  seq: number;
  pcm: Int16Array;
}

export function encodeFrame(epoch: number, seq: number, pcm: Int16Array): ArrayBuffer {
  const out = new ArrayBuffer(HEADER_BYTES + pcm.length * 2);
  const view = new DataView(out);
  view.setUint8(0, FRAME_VERSION);
  view.setUint8(1, epoch & 0xff);
  view.setUint16(2, seq & 0xffff, false);
  // PCM16 little-endian regardless of host endianness.
  for (let i = 0; i < pcm.length; i += 1) view.setInt16(HEADER_BYTES + i * 2, pcm[i], true);
  return out;
}

export function decodeFrame(data: ArrayBuffer): AudioFrame | null {
  if (data.byteLength < HEADER_BYTES) return null;
  const view = new DataView(data);
  if (view.getUint8(0) !== FRAME_VERSION) return null;
  const pcmBytes = data.byteLength - HEADER_BYTES;
  if (pcmBytes % 2 !== 0) return null;
  const pcm = new Int16Array(pcmBytes / 2);
  for (let i = 0; i < pcm.length; i += 1) pcm[i] = view.getInt16(HEADER_BYTES + i * 2, true);
  return { version: FRAME_VERSION, epoch: view.getUint8(1), seq: view.getUint16(2, false), pcm };
}
