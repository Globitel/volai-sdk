package com.globitel.volai

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
import okhttp3.Request
import org.json.JSONObject
import java.util.UUID

/**
 * A chat session: messages over REST, events over server-sent events.
 * The event stream reconnects with the last cursor until [close].
 */
class ChatSession internal constructor(private val client: VolaiClient, val info: ChatSessionInfo) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var pump: Job? = null
    private var cursor: String? = null
    private val _events = MutableSharedFlow<JSONObject>(replay = 0, extraBufferCapacity = 256, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Every event the server sends: `chat`, `chunk`, `chat_complete`, `human_chat`, `typing`, `system`,
     *  `LIVE_AGENT_CONNECTED`, `LIVE_AGENT_DISCONNECTED`, `SESSION_ENDED`, `error`, ... */
    val events: SharedFlow<JSONObject> = _events

    @Volatile
    var isClosed: Boolean = false
        private set

    /** Opens the event stream. Idempotent. */
    fun start() {
        if (pump != null || isClosed) return
        pump = scope.launch {
            while (isActive && !isClosed) {
                try {
                    pumpOnce()
                } catch (e: Exception) {
                    if (isClosed || !isActive) return@launch
                    _events.tryEmit(JSONObject().put("type", "stream_error").put("message", e.message ?: e.toString()))
                }
                if (!isClosed) delay(1000)
            }
        }
    }

    private fun pumpOnce() {
        val url = buildString {
            append(info.eventsUrl)
            append(if (info.eventsUrl.contains('?')) '&' else '?')
            append("chat_token=").append(java.net.URLEncoder.encode(info.chatToken, "UTF-8"))
            cursor?.let { append("&cursor=").append(java.net.URLEncoder.encode(it, "UTF-8")) }
        }
        val request = Request.Builder().url(url).header("Accept", "text/event-stream").get().build()
        VolaiClient.debug { "chat events: connecting (cursor=${cursor ?: "none"})" }
        client.http.newCall(request).execute().use { response ->
            VolaiClient.debug { "chat events: status ${response.code}" }
            if (response.code == 401 || response.code == 404) {
                isClosed = true
                _events.tryEmit(JSONObject().put("type", "SESSION_ENDED").put("reason", "token_rejected"))
                return
            }
            val parser = SseParser { event ->
                _events.tryEmit(event)
                if (event.optString("type") == "SESSION_ENDED") isClosed = true
            }
            val source = response.body?.source() ?: return
            while (!isClosed) {
                val line = source.readUtf8Line() ?: break
                parser.feed(line)
                parser.lastId?.let { cursor = it }
            }
            parser.finish()
        }
    }

    /** Sends a user message; returns the message id (generated when not given). */
    suspend fun send(content: String, messageId: String = UUID.randomUUID().toString(), attachment: JSONObject? = null): String {
        val body = JSONObject().put("message_id", messageId).put("content", content)
        attachment?.let { body.put("attachment", it) }
        client.request("/sessions/${info.sessionId}/messages", "POST", key = info.chatToken, body = body)
        return messageId
    }

    suspend fun acknowledge(messageId: String, status: String) {
        client.request("/sessions/${info.sessionId}/acks", "POST", key = info.chatToken,
            body = JSONObject().put("message_id", messageId).put("status", status))
    }

    suspend fun typing() {
        client.request("/sessions/${info.sessionId}/typing", "POST", key = info.chatToken)
    }

    suspend fun close() {
        if (isClosed) return
        isClosed = true
        pump?.cancel()
        pump = null
        try { client.request("/sessions/${info.sessionId}/close", "POST", key = info.chatToken) } catch (_: Exception) {}
        scope.cancel()
    }
}
