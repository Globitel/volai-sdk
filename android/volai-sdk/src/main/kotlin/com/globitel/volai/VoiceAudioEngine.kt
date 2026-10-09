package com.globitel.volai

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor

/**
 * Microphone capture and PCM playback with AudioRecord and AudioTrack.
 *
 * Capture: VOICE_COMMUNICATION source at 16 kHz mono, which gives the
 * platform's echo cancellation path; frames of 20 ms (320 samples) go to
 * [onFrame]. Playback: a streaming AudioTrack at 24 kHz fed by a writer
 * thread pulling from the [PlaybackBuffer]. The audio manager is put in
 * MODE_IN_COMMUNICATION for the duration of the call.
 */
internal class VoiceAudioEngine(private val context: Context, private val playback: PlaybackBuffer) {
    @Volatile var muted = false
    @Volatile var playbackMuted = false
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var captureThread: Thread? = null
    private var playThread: Thread? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var previousMode = AudioManager.MODE_NORMAL

    /** Throws SecurityException when RECORD_AUDIO was not granted. */
    fun start(onFrame: (ShortArray) -> Unit) {
        if (running) return
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        previousMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        val minRecord = AudioRecord.getMinBufferSize(AudioFrame.UPLINK_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            AudioFrame.UPLINK_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minRecord, AudioFrame.UPLINK_SAMPLES * 2 * 4),
        )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            audioManager.mode = previousMode
            throw VolaiException.Transport("AudioRecord could not be initialised")
        }
        if (AcousticEchoCanceler.isAvailable()) echoCanceler = AcousticEchoCanceler.create(recorder.audioSessionId)?.apply { enabled = true }
        if (NoiseSuppressor.isAvailable()) noiseSuppressor = NoiseSuppressor.create(recorder.audioSessionId)?.apply { enabled = true }

        val minTrack = AudioTrack.getMinBufferSize(AudioFrame.DOWNLINK_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val player = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(AudioFrame.DOWNLINK_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build())
            .setBufferSizeInBytes(maxOf(minTrack, AudioFrame.DOWNLINK_SAMPLES * 2 * 6))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        record = recorder
        track = player
        running = true
        recorder.startRecording()
        player.play()

        captureThread = Thread({
            val frame = ShortArray(AudioFrame.UPLINK_SAMPLES)
            while (running) {
                var filled = 0
                while (running && filled < frame.size) {
                    val n = recorder.read(frame, filled, frame.size - filled)
                    if (n <= 0) break
                    filled += n
                }
                if (filled == frame.size && !muted) onFrame(frame.copyOf())
            }
        }, "volai-capture").apply { priority = Thread.MAX_PRIORITY; start() }

        playThread = Thread({
            val chunk = ShortArray(AudioFrame.DOWNLINK_SAMPLES)
            while (running) {
                playback.pull(chunk)
                if (playbackMuted) chunk.fill(0)
                // Blocking write keeps this loop at real time.
                val written = player.write(chunk, 0, chunk.size)
                if (written < 0) break
            }
        }, "volai-playback").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        if (!running) return
        running = false
        captureThread?.join(500)
        playThread?.join(500)
        captureThread = null
        playThread = null
        echoCanceler?.release(); echoCanceler = null
        noiseSuppressor?.release(); noiseSuppressor = null
        record?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        track?.let { try { it.pause(); it.flush(); it.stop() } catch (_: Exception) {}; it.release() }
        record = null
        track = null
        (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).mode = previousMode
    }
}
