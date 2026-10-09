// Binary frame codec for the ws_audio voice transport
// (docs/sdk/voice-ws-protocol.md). Both directions share the header:
//   byte 0   version (1)
//   byte 1   playback epoch (downlink) / 0 (uplink)
//   bytes 2-3 uint16 big-endian sequence number, wraps
//   bytes 4..n PCM16 little-endian mono
export const FRAME_VERSION = 1;
export const HEADER_BYTES = 4;
export const UPLINK_RATE = 16000;
export const DOWNLINK_RATE = 24000;
export const FRAME_MS = 20;
export const UPLINK_FRAME_BYTES = (UPLINK_RATE / 1000) * FRAME_MS * 2;     // 640
export const DOWNLINK_FRAME_BYTES = (DOWNLINK_RATE / 1000) * FRAME_MS * 2; // 960

export function encodeFrame({ epoch = 0, seq = 0, pcm }) {
    const header = Buffer.alloc(HEADER_BYTES);
    header[0] = FRAME_VERSION;
    header[1] = epoch & 0xff;
    header.writeUInt16BE(seq & 0xffff, 2);
    return Buffer.concat([header, pcm]);
}

/** Returns { version, epoch, seq, pcm } or null for anything malformed. */
export function decodeFrame(buf) {
    if (!Buffer.isBuffer(buf) || buf.length < HEADER_BYTES || buf[0] !== FRAME_VERSION) return null;
    const pcm = buf.subarray(HEADER_BYTES);
    if (pcm.length % 2 !== 0) return null;
    return { version: buf[0], epoch: buf[1], seq: buf.readUInt16BE(2), pcm };
}

export function isSilentPcm16(buf) {
    for (let i = 0; i < buf.length; i += 1) {
        if (buf[i] !== 0) return false;
    }
    return true;
}

/** Sum two PCM16LE buffers sample-wise with clipping; result has a's length. */
export function mixPcm16(a, b) {
    const out = Buffer.alloc(a.length);
    const n = Math.min(a.length, b.length) >> 1;
    for (let i = 0; i < n; i += 1) {
        let v = a.readInt16LE(i * 2) + b.readInt16LE(i * 2);
        if (v > 32767) v = 32767;
        else if (v < -32768) v = -32768;
        out.writeInt16LE(v, i * 2);
    }
    if (a.length > n * 2) a.copy(out, n * 2, n * 2);
    return out;
}

export function pcm16DurationMs(bytes, rate) {
    return bytes / ((rate / 1000) * 2);
}

/**
 * Byte queue that hands out fixed-size slices (used to frame arbitrary PCM
 * chunks from ffmpeg into pacer-sized pieces). Drops the oldest bytes past
 * `maxBytes` so a stalled consumer never grows memory.
 */
export class PcmByteQueue {
    constructor(maxBytes) {
        this.maxBytes = maxBytes;
        this.chunks = [];
        this.bytes = 0;
        this.dropped = 0;
    }

    push(chunk) {
        this.chunks.push(chunk);
        this.bytes += chunk.length;
        while (this.bytes > this.maxBytes && this.chunks.length > 0) {
            const old = this.chunks.shift();
            this.bytes -= old.length;
            this.dropped += old.length;
        }
    }

    /** Take exactly `n` bytes, zero-padded when short; null when empty. */
    take(n) {
        if (this.bytes === 0) return null;
        const out = Buffer.alloc(n);
        let filled = 0;
        while (filled < n && this.chunks.length > 0) {
            const head = this.chunks[0];
            const need = n - filled;
            if (head.length <= need) {
                head.copy(out, filled);
                filled += head.length;
                this.chunks.shift();
            } else {
                head.copy(out, filled, 0, need);
                this.chunks[0] = head.subarray(need);
                filled += need;
            }
        }
        this.bytes -= filled;
        return out;
    }

    clear() {
        this.chunks = [];
        this.bytes = 0;
    }
}
