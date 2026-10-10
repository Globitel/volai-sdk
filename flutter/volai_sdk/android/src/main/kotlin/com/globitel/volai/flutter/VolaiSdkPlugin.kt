package com.globitel.volai.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.globitel.volai.ChatSession
import com.globitel.volai.SessionReady
import com.globitel.volai.SessionRequest
import com.globitel.volai.VoiceCall
import com.globitel.volai.VolaiClient
import com.globitel.volai.VolaiException
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Flutter bridge over the Volai Android library vendored in
 * src/main/kotlin/com/globitel/volai (scripts/sync-native.sh). Methods on
 * `com.globitel.volai/sdk`, events on `com.globitel.volai/events` as maps
 * with `kind` = chat | voice.
 */
class VolaiSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var appContext: Context
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var client: VolaiClient? = null
    private val chats = HashMap<String, ChatSession>()
    private val chatPumps = HashMap<String, Job>()
    private val calls = HashMap<String, VoiceCall>()
    private val callPumps = HashMap<String, Job>()
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.globitel.volai/sdk")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "com.globitel.volai/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { this.sink = sink }
    override fun onCancel(arguments: Any?) { sink = null }

    private fun emit(body: Map<String, Any?>) { main.post { sink?.success(body) } }

    private fun MethodChannel.Result.ok(value: Any?) { main.post { success(value) } }

    private fun MethodChannel.Result.fail(e: Throwable) {
        main.post {
            when (e) {
                is VolaiException.Api -> error(e.code ?: "api_${e.status}", e.message, mapOf("status" to e.status, "reason" to e.reason))
                else -> error("volai_error", e.message ?: e.toString(), null)
            }
        }
    }

    private fun sessionRequest(map: Map<*, *>): SessionRequest = SessionRequest(
        agentId = map["agentId"] as? String ?: "",
        deviceId = map["deviceId"] as? String,
        callerName = map["callerName"] as? String,
        callerPhone = map["callerPhone"] as? String,
        callerEmail = map["callerEmail"] as? String,
        context = (map["context"] as? Map<*, *>)?.let { m -> m.entries.associate { it.key.toString() to it.value } },
        verificationTokens = (map["verificationTokens"] as? Map<*, *>)?.let { m -> m.entries.associate { it.key.toString() to it.value } },
        sessionGrant = map["sessionGrant"] as? String,
        publicLinkPassword = map["publicLinkPassword"] as? String,
    )

    private fun readyMap(r: SessionReady): Map<String, Any?> = mapOf(
        "session_id" to r.sessionId, "epoch" to r.epoch, "resume_token" to r.resumeToken, "grace_ms" to r.graceMs, "resumed" to r.resumed,
        "uplink" to mapOf("rate" to r.uplinkRate, "frame_ms" to r.frameMs), "downlink" to mapOf("rate" to r.downlinkRate, "frame_ms" to r.frameMs),
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val baseUrl = call.argument<String>("baseUrl"); val appKey = call.argument<String>("appKey")
                if (baseUrl == null || appKey == null) return result.error("bad_args", "baseUrl and appKey are required", null)
                client = VolaiClient(baseUrl, appKey, sdkName = "volai-flutter")
                result.success(null)
            }
            "getAgent" -> {
                val client = requireClient(result) ?: return
                val agentId = call.argument<String>("agentId") ?: return result.error("bad_args", "agentId is required", null)
                scope.launch { try { result.ok(jsonToMap(client.getAgent(agentId).json)) } catch (e: Exception) { result.fail(e) } }
            }
            "createChat" -> {
                val client = requireClient(result) ?: return
                val request = sessionRequest(call.argument<Map<*, *>>("request") ?: emptyMap<String, Any>())
                scope.launch {
                    try {
                        val chat = client.createChat(request)
                        synchronized(chats) { chats[chat.info.sessionId] = chat }
                        result.ok(mapOf(
                            "sessionId" to chat.info.sessionId, "chatToken" to chat.info.chatToken, "eventsUrl" to chat.info.eventsUrl,
                            "initialGreeting" to chat.info.initialGreeting?.let { (id, content) -> mapOf("id" to id, "content" to content) },
                        ))
                    } catch (e: Exception) { result.fail(e) }
                }
            }
            "startChat" -> {
                val chat = requireChat(call, result) ?: return
                val sessionId = chat.info.sessionId
                if (chatPumps[sessionId] == null) {
                    chatPumps[sessionId] = scope.launch {
                        chat.events.collect { event -> emit(mapOf("kind" to "chat", "sessionId" to sessionId, "event" to jsonToMap(event))) }
                    }
                }
                chat.start()
                result.success(null)
            }
            "sendChatMessage" -> {
                val chat = requireChat(call, result) ?: return
                val content = call.argument<String>("content") ?: return result.error("bad_args", "content is required", null)
                val messageId = call.argument<String>("messageId") ?: UUID.randomUUID().toString()
                scope.launch { try { result.ok(chat.send(content, messageId)) } catch (e: Exception) { result.fail(e) } }
            }
            "ackChatMessage" -> {
                val chat = requireChat(call, result) ?: return
                val messageId = call.argument<String>("messageId") ?: ""; val status = call.argument<String>("status") ?: "read"
                scope.launch { try { chat.acknowledge(messageId, status); result.ok(null) } catch (e: Exception) { result.fail(e) } }
            }
            "chatTyping" -> {
                val chat = requireChat(call, result) ?: return
                scope.launch { try { chat.typing(); result.ok(null) } catch (e: Exception) { result.fail(e) } }
            }
            "closeChat" -> {
                val sessionId = call.argument<String>("sessionId") ?: return result.success(null)
                val chat = synchronized(chats) { chats.remove(sessionId) } ?: return result.success(null)
                chatPumps.remove(sessionId)?.cancel()
                scope.launch { chat.close(); result.ok(null) }
            }
            "createVoice" -> {
                val client = requireClient(result) ?: return
                val request = sessionRequest(call.argument<Map<*, *>>("request") ?: emptyMap<String, Any>())
                val mode = if (call.argument<String>("mode") == "half_duplex") VoiceCall.Mode.HALF_DUPLEX else VoiceCall.Mode.FULL_DUPLEX
                scope.launch {
                    try {
                        val voice = client.createVoice(request, mode)
                        val callId = UUID.randomUUID().toString()
                        synchronized(calls) { calls[callId] = voice }
                        callPumps[callId] = scope.launch {
                            voice.events.collect { event ->
                                emit(voiceEvent(callId, event))
                                if (event is VoiceCall.Event.Ended) { synchronized(calls) { calls.remove(callId) } }
                            }
                        }
                        result.ok(mapOf(
                            "callId" to callId, "sessionId" to voice.info.sessionId, "transport" to voice.info.transport,
                            "wsUrl" to voice.info.wsUrl, "wsTokenExpiresIn" to voice.info.wsTokenExpiresIn,
                        ))
                    } catch (e: Exception) { result.fail(e) }
                }
            }
            "connectVoice" -> {
                val voice = requireCall(call, result) ?: return
                scope.launch { try { result.ok(readyMap(voice.connect(appContext))) } catch (e: Exception) { result.fail(e) } }
            }
            "setVoiceMuted" -> { requireCall(call, result)?.setMuted(call.argument<Boolean>("muted") ?: false) ?: return; result.success(null) }
            "setVoicePlaybackMuted" -> { requireCall(call, result)?.setPlaybackMuted(call.argument<Boolean>("muted") ?: false) ?: return; result.success(null) }
            "endVoice" -> { requireCall(call, result)?.end(call.argument<String>("reason") ?: "user_hangup") ?: return; result.success(null) }
            "setSocketUrlOverride" -> {
                val voice = requireCall(call, result) ?: return
                voice.socketUrlOverride = call.argument<String>("url")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requireClient(result: MethodChannel.Result): VolaiClient? =
        client ?: run { result.error("not_configured", "Create a VolaiClient first", null); null }

    private fun requireChat(call: MethodCall, result: MethodChannel.Result): ChatSession? {
        val sessionId = call.argument<String>("sessionId")
        return synchronized(chats) { chats[sessionId] } ?: run { result.error("unknown_session", "No chat session $sessionId", null); null }
    }

    private fun requireCall(call: MethodCall, result: MethodChannel.Result): VoiceCall? {
        val callId = call.argument<String>("callId")
        return synchronized(calls) { calls[callId] } ?: run { result.error("unknown_call", "No voice call $callId", null); null }
    }

    private fun voiceEvent(callId: String, event: VoiceCall.Event): Map<String, Any?> {
        val body = HashMap<String, Any?>(); body["kind"] = "voice"; body["callId"] = callId
        when (event) {
            is VoiceCall.Event.Ready -> { body["type"] = "ready"; body["ready"] = readyMap(event.ready) }
            is VoiceCall.Event.StateChanged -> { body["type"] = "state"; body["state"] = event.state.name.lowercase() }
            is VoiceCall.Event.Transcript -> { body["type"] = "transcript"; body["side"] = event.side; body["text"] = event.text; body["raw"] = jsonToMap(event.raw) }
            is VoiceCall.Event.AgentSpeaking -> { body["type"] = "agentSpeaking"; body["speaking"] = event.speaking }
            is VoiceCall.Event.Interrupted -> { body["type"] = "interrupted"; body["epoch"] = event.epoch; body["reason"] = event.reason }
            is VoiceCall.Event.System -> { body["type"] = "system"; body["content"] = event.content }
            is VoiceCall.Event.Message -> { body["type"] = "message"; body["raw"] = jsonToMap(event.raw) }
            is VoiceCall.Event.Error -> { body["type"] = "error"; body["code"] = event.code; body["message"] = event.message; body["fatal"] = event.fatal }
            is VoiceCall.Event.Ended -> { body["type"] = "ended"; body["reason"] = event.reason }
        }
        return body
    }

    private fun jsonToMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { key -> jsonValue(json.opt(key)) }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonToMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
        else -> value
    }
}
