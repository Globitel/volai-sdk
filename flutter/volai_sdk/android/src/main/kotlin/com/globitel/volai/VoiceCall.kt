package com.globitel.volai

import android.content.Context
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject

/**
 * One voice call on the ws_audio transport (docs/voice-ws-protocol.md).
 *
 * [connect] opens the socket, sends `client.hello`, starts playback and
 * capture, and returns on `session.ready`. An abnormal socket loss resumes
 * within the server's grace window; a clean close or [end] finishes the call.
 * Events arrive on [events].
 */
class VoiceCall internal constructor(
    val info: VoiceSessionInfo,
    val mode: Mode,
    private val http: OkHttpClient,
    private val sdkName: String,
    private val sdkVersion: String,
) {
    enum class Mode(val wire: String) { FULL_DUPLEX("full_duplex"), HALF_DUPLEX("half_duplex") }
    enum class State { IDLE, CONNECTING, CONNECTED, RECONNECTING, ENDED }

    sealed class Event {
        data class Ready(val ready: SessionReady) : Event()
        data class StateChanged(val state: State) : Event()
        data class Transcript(val side: String, val text: String, val raw: JSONObject) : Event()
        data class AgentSpeaking(val speaking: Boolean) : Event()
        data class Interrupted(val epoch: Int, val reason: String) : Event()
        data class System(val content: String) : Event()
        data class Message(val raw: JSONObject) : Event()
        data class Error(val code: String?, val message: String, val fatal: Boolean) : Event()
        data class Ended(val reason: String) : Event()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _events = MutableSharedFlow<Event>(replay = 0, extraBufferCapacity = 256, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val events: SharedFlow<Event> = _events

    @Volatile var state: State = State.IDLE
        private set
    @Volatile var ready: SessionReady? = null
        private set
    @Volatile var muted: Boolean = false
        private set

    private val playback = PlaybackBuffer()
    private var audio: VoiceAudioEngine? = null
    private var socket: WebSocket? = null
    private var pingJob: Job? = null
    private var seq = 0
    @Volatile private var ended = false
    @Volatile private var endRequested = false
    private var reconnectDeadline = 0L
    private var readyDeferred: CompletableDeferred<SessionReady>? = null
    /** Development only: rewrites the socket origin (e.g. a dev stack's separate WebSocket port). */
    var socketUrlOverride: String? = null

    /** Opens the call. Returns on `session.ready`; throws on socket or microphone failure. */
    suspend fun connect(context: Context, readyTimeoutMs: Long = 20_000): SessionReady {
        check(state == State.IDLE) { "connect() may only be called once" }
        setState(State.CONNECTING)
        val deferred = CompletableDeferred<SessionReady>()
        readyDeferred = deferred
        open(socketUrlOverride ?: info.wsUrl)
        val ready = try {
            withTimeout(readyTimeoutMs) { deferred.await() }
        } catch (e: Exception) {
            finish("connect_failed")
            throw if (e is VolaiException) e else VolaiException.Transport("voice socket did not become ready: ${e.message}")
        }
        val engine = VoiceAudioEngine(context.applicationContext, playback)
        try {
            engine.start { frame -> sendUplink(frame) }
        } catch (e: Exception) {
            finish("mic_failed")
            throw e
        }
        audio = engine
        return ready
    }

    fun setMuted(muted: Boolean) {
        this.muted = muted
        audio?.muted = muted
        send(JSONObject().put("type", "mic.muted").put("muted", muted))
    }

    /** Silences local playback without stopping the stream. */
    fun setPlaybackMuted(muted: Boolean) { audio?.playbackMuted = muted }

    /** Hangs up: tells the server, then releases the audio devices. */
    fun end(reason: String = "user_hangup") {
        if (ended) return
        endRequested = true
        send(JSONObject().put("type", "session.end").put("reason", reason))
        socket?.close(1000, "end")
        finish("user_ended")
    }

    // ---- socket -------------------------------------------------------------

    private fun open(url: String) {
        val request = Request.Builder().url(url).header("User-Agent", "$sdkName/$sdkVersion").build()
        val ws = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(JSONObject().put("type", "client.hello").put("sdk", sdkName).put("version", sdkVersion)
                    .put("platform", "android").put("mode", mode.wire).toString())
            }
            override fun onMessage(webSocket: WebSocket, text: String) = handleControl(text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handleDownlink(bytes.toByteArray())
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = onSocketClosed(webSocket, code, reason)
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = onSocketClosed(webSocket, 1006, t.message ?: "failure")
        })
        socket = ws
        startPing()
    }

    private fun onSocketClosed(ws: WebSocket, code: Int, reason: String) {
        if (ws !== socket || ended) return
        val clean = endRequested || code == 1000 || code == 1001 || code == 1008
        val current = ready
        if (clean || current == null) {
            readyDeferred?.completeExceptionally(VolaiException.Transport("voice socket closed before session.ready ($code $reason)"))
            readyDeferred = null
            finish(if (endRequested) "user_ended" else "socket_closed")
            return
        }
        if (state != State.RECONNECTING) {
            reconnectDeadline = System.currentTimeMillis() + current.graceMs - 1000
            setState(State.RECONNECTING)
        }
        if (System.currentTimeMillis() >= reconnectDeadline) {
            finish("reconnect_failed")
            return
        }
        scope.launch {
            delay(500)
            if (!ended && isActive) open(resumeUrl(socketUrlOverride ?: info.wsUrl, current.sessionId, current.resumeToken))
        }
    }

    private fun send(message: JSONObject) { socket?.send(message.toString()) }

    private fun sendUplink(pcm: ShortArray) {
        if (state != State.CONNECTED || muted) return
        val frame = AudioFrame.encode(0, seq, pcm)
        seq = (seq + 1) and 0xffff
        socket?.send(frame.toByteString())
    }

    private fun startPing() {
        pingJob?.cancel()
        pingJob = scope.launch {
            while (isActive && !ended) {
                delay(5000)
                send(JSONObject().put("type", "ping").put("ts", System.currentTimeMillis()))
            }
        }
    }

    // ---- inbound --------------------------------------------------------------

    private fun handleDownlink(data: ByteArray) {
        val frame = AudioFrame.decode(data) ?: return
        playback.push(frame.epoch, frame.pcm)
    }

    private fun handleControl(text: String) {
        val json = try { JSONObject(text) } catch (_: Exception) { return }
        when (val type = json.optString("type")) {
            "session.ready" -> {
                val r = try { SessionReady.from(json) } catch (_: Exception) { return }
                ready = r
                playback.flush(r.epoch)
                setState(State.CONNECTED)
                _events.tryEmit(Event.Ready(r))
                readyDeferred?.complete(r)
                readyDeferred = null
            }
            "audio.interrupted" -> {
                val epoch = json.optInt("epoch", 0) and 0xff
                playback.flush(epoch)
                send(JSONObject().put("type", "playback.flushed").put("epoch", epoch))
                _events.tryEmit(Event.Interrupted(epoch, json.optString("reason")))
            }
            "speakStart" -> _events.tryEmit(Event.AgentSpeaking(true))
            "speakEnd" -> _events.tryEmit(Event.AgentSpeaking(false))
            "speech" -> _events.tryEmit(Event.Transcript(json.optString("side"), json.optString("utterance"), json))
            "system" -> _events.tryEmit(Event.System(json.optString("content")))
            "pong", "stats" -> Unit
            "session_ended", "SESSION_ENDED" -> { ended = true; finish(json.optString("reason").ifEmpty { "agent_ended" }) }
            "error", "fatal_error" -> {
                val fatal = json.optBoolean("fatal", type == "fatal_error")
                _events.tryEmit(Event.Error(json.optString("code").ifEmpty { null }, json.optString("message"), fatal))
                if (fatal) finish("error")
            }
            else -> _events.tryEmit(Event.Message(json))
        }
    }

    // ---- state ----------------------------------------------------------------

    private fun setState(new: State) {
        if (state == new) return
        state = new
        _events.tryEmit(Event.StateChanged(new))
    }

    private fun finish(reason: String) {
        if (state == State.ENDED) return
        ended = true
        pingJob?.cancel()
        audio?.stop()
        audio = null
        socket?.close(1000, null)
        socket = null
        setState(State.ENDED)
        _events.tryEmit(Event.Ended(reason))
        scope.cancel()
    }
}
