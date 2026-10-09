package com.globitel.volai

/**
 * Binary frame codec for the ws_audio voice transport (docs/voice-ws-protocol.md).
 * Header: version (1), playback epoch (downlink) or 0 (uplink), big-endian
 * uint16 sequence, then PCM16 little-endian mono.
 */
object AudioFrame {
    const val VERSION: Int = 1
    const val HEADER_BYTES: Int = 4
    const val UPLINK_RATE: Int = 16_000
    const val DOWNLINK_RATE: Int = 24_000
    const val FRAME_MS: Int = 20
    /** 320 samples: 20 ms at 16 kHz. */
    const val UPLINK_SAMPLES: Int = UPLINK_RATE / 1000 * FRAME_MS
    /** 480 samples: 20 ms at 24 kHz. */
    const val DOWNLINK_SAMPLES: Int = DOWNLINK_RATE / 1000 * FRAME_MS

    data class Decoded(val epoch: Int, val seq: Int, val pcm: ShortArray) {
        override fun equals(other: Any?): Boolean =
            other is Decoded && other.epoch == epoch && other.seq == seq && other.pcm.contentEquals(pcm)
        override fun hashCode(): Int = 31 * (31 * epoch + seq) + pcm.contentHashCode()
    }

    fun encode(epoch: Int, seq: Int, pcm: ShortArray): ByteArray {
        val out = ByteArray(HEADER_BYTES + pcm.size * 2)
        out[0] = VERSION.toByte()
        out[1] = (epoch and 0xff).toByte()
        out[2] = ((seq shr 8) and 0xff).toByte()
        out[3] = (seq and 0xff).toByte()
        var i = HEADER_BYTES
        for (s in pcm) {
            out[i++] = (s.toInt() and 0xff).toByte()
            out[i++] = ((s.toInt() shr 8) and 0xff).toByte()
        }
        return out
    }

    /** Returns null for anything malformed (wrong version, short header, odd payload). */
    fun decode(data: ByteArray): Decoded? {
        if (data.size < HEADER_BYTES || data[0].toInt() != VERSION) return null
        val payload = data.size - HEADER_BYTES
        if (payload % 2 != 0) return null
        val epoch = data[1].toInt() and 0xff
        val seq = ((data[2].toInt() and 0xff) shl 8) or (data[3].toInt() and 0xff)
        val pcm = ShortArray(payload / 2)
        var i = HEADER_BYTES
        for (k in pcm.indices) {
            val lo = data[i++].toInt() and 0xff
            val hi = data[i++].toInt() and 0xff
            pcm[k] = ((hi shl 8) or lo).toShort()
        }
        return Decoded(epoch, seq, pcm)
    }
}
