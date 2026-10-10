package com.globitel.volai

import java.util.ArrayDeque

/**
 * Queue of downlink PCM (24 kHz) with the playback epoch rule: frames from
 * another epoch are dropped and a flush empties everything buffered, so a
 * barge-in cuts playback at once. Thread-safe; pulled by the AudioTrack
 * writer thread.
 */
class PlaybackBuffer(private val sampleRate: Int = AudioFrame.DOWNLINK_RATE, prebufferMs: Int = 60) {
    private val lock = Any()
    private val queue = ArrayDeque<ShortArray>()
    private var headOffset = 0
    private var queuedSamples = 0
    private var primed = false
    private val prebufferSamples = sampleRate / 1000 * prebufferMs

    @Volatile
    var epoch: Int = 0
        private set

    val bufferedMs: Int
        get() = synchronized(lock) { queuedSamples * 1000 / sampleRate }

    fun push(epoch: Int, pcm: ShortArray) {
        if (pcm.isEmpty()) return
        synchronized(lock) {
            if (epoch != this.epoch) return
            queue.addLast(pcm)
            queuedSamples += pcm.size
        }
    }

    fun flush(toEpoch: Int) {
        synchronized(lock) {
            epoch = toEpoch and 0xff
            queue.clear()
            headOffset = 0
            queuedSamples = 0
            primed = false
        }
    }

    /**
     * Fills [out] with queued samples at the source rate, zero-padding when
     * the queue runs dry (or while priming). Returns the number of real samples.
     */
    fun pull(out: ShortArray): Int {
        synchronized(lock) {
            if (!primed) {
                if (queuedSamples < prebufferSamples) {
                    out.fill(0)
                    return 0
                }
                primed = true
            }
            var filled = 0
            while (filled < out.size) {
                val head = queue.peekFirst()
                if (head == null) {
                    primed = false
                    break
                }
                val n = minOf(out.size - filled, head.size - headOffset)
                System.arraycopy(head, headOffset, out, filled, n)
                filled += n
                headOffset += n
                queuedSamples -= n
                if (headOffset >= head.size) {
                    queue.removeFirst()
                    headOffset = 0
                }
            }
            if (filled < out.size) out.fill(0, filled, out.size)
            return filled
        }
    }
}
