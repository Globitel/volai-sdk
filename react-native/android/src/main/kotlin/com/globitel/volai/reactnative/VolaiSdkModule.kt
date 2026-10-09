package com.globitel.volai.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.globitel.volai.ChatSession
import com.globitel.volai.SessionReady
import com.globitel.volai.SessionRequest
import com.globitel.volai.VoiceCall
import com.globitel.volai.VolaiClient
import com.globitel.volai.VolaiException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * React Native bridge over the Volai Android library vendored in
 * src/main/kotlin/com/globitel/volai (scripts/sync-native.sh). Promise-based
 * methods; events on `VolaiChatEvent` and `VolaiVoiceEvent`.
 */
class VolaiSdkModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var client: VolaiClient? = null
    private val chats = HashMap<String, ChatSession>()
    private val chatPumps = HashMap<String, Job>()
    private val calls = HashMap<String, VoiceCall>()
    private val callPumps = HashMap<String, Job>()

    override fun getName() = "VolaiSdk"

    private fun emit(name: String, body: WritableMap) {
        reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit(name, body)
    }

    private fun Promise.fail(e: Throwable) {
        when (e) {
            is VolaiException.Api -> reject(e.code ?: "api_${e.status}", e.message, e)
            else -> reject("volai_error", e.message ?: e.toString(), e)
        }
    }

    private fun requireClient(promise: Promise): VolaiClient? =
        client ?: run { promise.reject("not_configured", "Call configure(baseUrl, appKey) first"); null }

    private fun sessionRequest(map: ReadableMap): SessionRequest = SessionRequest(
        agentId = map.getString("agentId") ?: "",
        deviceId = map.getString("deviceId"),
        callerName = map.getString("callerName"),
        callerPhone = map.getString("callerPhone"),
        callerEmail = map.getString("callerEmail"),
        context = if (map.hasKey("context")) map.getMap("context")?.toHashMap() else null,
        verificationTokens = if (map.hasKey("verificationTokens")) map.getMap("verificationTokens")?.toHashMap() else null,
        sessionGrant = map.getString("sessionGrant"),
        publicLinkPassword = map.getString("publicLinkPassword"),
    )

    private fun readyMap(r: SessionReady): WritableMap = Arguments.createMap().apply {
        putString("session_id", r.sessionId); putInt("epoch", r.epoch); putString("resume_token", r.resumeToken)
        putInt("grace_ms", r.graceMs); putBoolean("resumed", r.resumed)
        putMap("uplink", Arguments.createMap().apply { putInt("rate", r.uplinkRate); putInt("frame_ms", r.frameMs) })
        putMap("downlink", Arguments.createMap().apply { putInt("rate", r.downlinkRate); putInt("frame_ms", r.frameMs) })
    }

    // ---- client -------------------------------------------------------------

    @ReactMethod
    fun configure(baseUrl: String, appKey: String, promise: Promise) {
        client = VolaiClient(baseUrl, appKey, sdkName = "volai-react-native")
        promise.resolve(null)
    }

    @ReactMethod
    fun getAgent(agentId: String, promise: Promise) {
        val client = requireClient(promise) ?: return
        scope.launch { try { promise.resolve(jsonToMap(client.getAgent(agentId).json)) } catch (e: Exception) { promise.fail(e) } }
    }

    // ---- chat -----------------------------------------------------------------

    @ReactMethod
    fun createChat(request: ReadableMap, promise: Promise) {
        val client = requireClient(promise) ?: return
        scope.launch {
            try {
                val chat = client.createChat(sessionRequest(request))
                synchronized(chats) { chats[chat.info.sessionId] = chat }
                promise.resolve(Arguments.createMap().apply {
                    putString("sessionId", chat.info.sessionId); putString("chatToken", chat.info.chatToken); putString("eventsUrl", chat.info.eventsUrl)
                    chat.info.initialGreeting?.let { (id, content) -> putMap("initialGreeting", Arguments.createMap().apply { putString("id", id); putString("content", content) }) } ?: putNull("initialGreeting")
                })
            } catch (e: Exception) { promise.fail(e) }
        }
    }

    @ReactMethod
    fun startChat(sessionId: String, promise: Promise) {
        val chat = synchronized(chats) { chats[sessionId] } ?: return promise.reject("unknown_session", "No chat session $sessionId")
        if (chatPumps[sessionId] == null) {
            chatPumps[sessionId] = scope.launch {
                chat.events.collect { event ->
                    emit("VolaiChatEvent", Arguments.createMap().apply { putString("sessionId", sessionId); putMap("event", jsonToMap(event)) })
                }
            }
        }
        chat.start()
        promise.resolve(null)
    }

    @ReactMethod
    fun sendChatMessage(sessionId: String, content: String, messageId: String?, promise: Promise) {
        val chat = synchronized(chats) { chats[sessionId] } ?: return promise.reject("unknown_session", "No chat session $sessionId")
        scope.launch { try { promise.resolve(chat.send(content, messageId ?: UUID.randomUUID().toString())) } catch (e: Exception) { promise.fail(e) } }
    }

    @ReactMethod
    fun ackChatMessage(sessionId: String, messageId: String, status: String, promise: Promise) {
        val chat = synchronized(chats) { chats[sessionId] } ?: return promise.reject("unknown_session", "No chat session $sessionId")
        scope.launch { try { chat.acknowledge(messageId, status); promise.resolve(null) } catch (e: Exception) { promise.fail(e) } }
    }

    @ReactMethod
    fun chatTyping(sessionId: String, promise: Promise) {
        val chat = synchronized(chats) { chats[sessionId] } ?: return promise.reject("unknown_session", "No chat session $sessionId")
        scope.launch { try { chat.typing(); promise.resolve(null) } catch (e: Exception) { promise.fail(e) } }
    }

    @ReactMethod
    fun closeChat(sessionId: String, promise: Promise) {
        val chat = synchronized(chats) { chats.remove(sessionId) } ?: return promise.resolve(null)
        chatPumps.remove(sessionId)?.cancel()
        scope.launch { chat.close(); promise.resolve(null) }
    }

    // ---- voice ----------------------------------------------------------------

    @ReactMethod
    fun createVoice(request: ReadableMap, mode: String, promise: Promise) {
        val client = requireClient(promise) ?: return
        scope.launch {
            try {
                val call = client.createVoice(sessionRequest(request), if (mode == "half_duplex") VoiceCall.Mode.HALF_DUPLEX else VoiceCall.Mode.FULL_DUPLEX)
                val callId = UUID.randomUUID().toString()
                synchronized(calls) { calls[callId] = call }
                callPumps[callId] = scope.launch {
                    call.events.collect { event ->
                        emit("VolaiVoiceEvent", voiceEvent(callId, event))
                        if (event is VoiceCall.Event.Ended) { synchronized(calls) { calls.remove(callId) } }
                    }
                }
                promise.resolve(Arguments.createMap().apply {
                    putString("callId", callId); putString("sessionId", call.info.sessionId); putString("transport", call.info.transport)
                    putString("wsUrl", call.info.wsUrl); putInt("wsTokenExpiresIn", call.info.wsTokenExpiresIn)
                })
            } catch (e: Exception) { promise.fail(e) }
        }
    }

    @ReactMethod
    fun connectVoice(callId: String, promise: Promise) {
        val call = synchronized(calls) { calls[callId] } ?: return promise.reject("unknown_call", "No voice call $callId")
        scope.launch { try { promise.resolve(readyMap(call.connect(reactContext))) } catch (e: Exception) { promise.fail(e) } }
    }

    @ReactMethod
    fun setVoiceMuted(callId: String, muted: Boolean, promise: Promise) {
        synchronized(calls) { calls[callId] }?.setMuted(muted); promise.resolve(null)
    }

    @ReactMethod
    fun setVoicePlaybackMuted(callId: String, muted: Boolean, promise: Promise) {
        synchronized(calls) { calls[callId] }?.setPlaybackMuted(muted); promise.resolve(null)
    }

    @ReactMethod
    fun endVoice(callId: String, reason: String, promise: Promise) {
        synchronized(calls) { calls[callId] }?.end(reason); promise.resolve(null)
    }

    @ReactMethod
    fun setSocketUrlOverride(callId: String, url: String?, promise: Promise) {
        val call = synchronized(calls) { calls[callId] } ?: return promise.reject("unknown_call", "No voice call $callId")
        call.socketUrlOverride = url
        promise.resolve(null)
    }

    @ReactMethod fun addListener(eventName: String) { /* required by NativeEventEmitter */ }
    @ReactMethod fun removeListeners(count: Int) { /* required by NativeEventEmitter */ }

    private fun voiceEvent(callId: String, event: VoiceCall.Event): WritableMap = Arguments.createMap().apply {
        putString("callId", callId)
        when (event) {
            is VoiceCall.Event.Ready -> { putString("type", "ready"); putMap("ready", readyMap(event.ready)) }
            is VoiceCall.Event.StateChanged -> { putString("type", "state"); putString("state", event.state.name.lowercase()) }
            is VoiceCall.Event.Transcript -> { putString("type", "transcript"); putString("side", event.side); putString("text", event.text); putMap("raw", jsonToMap(event.raw)) }
            is VoiceCall.Event.AgentSpeaking -> { putString("type", "agentSpeaking"); putBoolean("speaking", event.speaking) }
            is VoiceCall.Event.Interrupted -> { putString("type", "interrupted"); putInt("epoch", event.epoch); putString("reason", event.reason) }
            is VoiceCall.Event.System -> { putString("type", "system"); putString("content", event.content) }
            is VoiceCall.Event.Message -> { putString("type", "message"); putMap("raw", jsonToMap(event.raw)) }
            is VoiceCall.Event.Error -> { putString("type", "error"); if (event.code == null) putNull("code") else putString("code", event.code); putString("message", event.message); putBoolean("fatal", event.fatal) }
            is VoiceCall.Event.Ended -> { putString("type", "ended"); putString("reason", event.reason) }
        }
    }

    private fun jsonToMap(json: JSONObject): WritableMap = Arguments.createMap().apply {
        for (key in json.keys()) putValue(this, key, json.opt(key))
    }

    private fun putValue(map: WritableMap, key: String, value: Any?) {
        when (value) {
            null, JSONObject.NULL -> map.putNull(key)
            is Boolean -> map.putBoolean(key, value)
            is Int -> map.putInt(key, value)
            is Long -> map.putDouble(key, value.toDouble())
            is Number -> map.putDouble(key, value.toDouble())
            is String -> map.putString(key, value)
            is JSONObject -> map.putMap(key, jsonToMap(value))
            is JSONArray -> map.putArray(key, Arguments.createArray().apply {
                for (i in 0 until value.length()) {
                    when (val v = value.opt(i)) {
                        null, JSONObject.NULL -> pushNull()
                        is Boolean -> pushBoolean(v)
                        is Int -> pushInt(v)
                        is Number -> pushDouble(v.toDouble())
                        is String -> pushString(v)
                        is JSONObject -> pushMap(jsonToMap(v))
                        else -> pushString(v.toString())
                    }
                }
            })
            else -> map.putString(key, value.toString())
        }
    }
}
