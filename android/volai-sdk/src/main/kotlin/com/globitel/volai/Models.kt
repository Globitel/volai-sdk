package com.globitel.volai

import org.json.JSONObject

/** Raised by the REST layer and the voice socket. */
sealed class VolaiException(message: String) : Exception(message) {
    /** Non-2xx answer; [code] and [reason] are the contract's machine-readable fields when present. */
    class Api(val status: Int, message: String, val code: String?, val reason: String?) : VolaiException("Volai API $status: $message")
    class Transport(message: String) : VolaiException(message)
    class UnsupportedTransport(val transport: String) : VolaiException("Server picked transport \"$transport\", which this SDK does not implement")
    class InvalidResponse(message: String) : VolaiException("Invalid response: $message")
}

private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null

/** Public agent information (GET /agents/{id}); [json] keeps every field. */
class PublicAgent internal constructor(val json: JSONObject) {
    val apiId: String = json.str("api_id") ?: throw VolaiException.InvalidResponse("agent lookup is missing api_id")
    val name: String = json.str("name") ?: ""
    val architecture: String? = json.str("agentArchitecture")
    val embedMode: String = json.str("embedMode") ?: "both"
    val voiceTransports: List<String> = json.optJSONArray("voiceTransports")?.let { arr -> List(arr.length()) { arr.getString(it) } } ?: listOf("webrtc")
    val defaultVoiceTransport: String = json.str("defaultVoiceTransport") ?: "webrtc"
    val publicLinkPasswordRequired: Boolean = json.optBoolean("publicLinkPasswordRequired", false)
}

class VoiceSessionInfo internal constructor(json: JSONObject) {
    val sessionId: String = json.str("session_id") ?: throw VolaiException.InvalidResponse("voice session is missing session_id")
    val transport: String = json.str("transport") ?: throw VolaiException.InvalidResponse("voice session is missing transport")
    val wsUrl: String = json.str("ws_url") ?: throw VolaiException.InvalidResponse("voice session is missing ws_url")
    val wsToken: String = json.str("ws_token") ?: throw VolaiException.InvalidResponse("voice session is missing ws_token")
    val wsTokenExpiresIn: Int = json.optInt("ws_token_expires_in", 30)
}

class ChatSessionInfo internal constructor(json: JSONObject) {
    val sessionId: String = json.str("session_id") ?: throw VolaiException.InvalidResponse("chat session is missing session_id")
    val chatToken: String = json.str("chat_token") ?: throw VolaiException.InvalidResponse("chat session is missing chat_token")
    val eventsUrl: String = json.str("events_url") ?: throw VolaiException.InvalidResponse("chat session is missing events_url")
    val initialGreeting: Pair<String, String>? = json.optJSONObject("initial_greeting")?.let { g ->
        val id = g.str("id"); val content = g.str("content")
        if (id != null && content != null) id to content else null
    }
    val idleMinutes: Int? = if (json.has("idle_minutes") && !json.isNull("idle_minutes")) json.getInt("idle_minutes") else null
    val expiresAt: String? = json.str("expires_at")
}

/** `session.ready` from the voice socket. */
data class SessionReady(
    val sessionId: String,
    val uplinkRate: Int,
    val downlinkRate: Int,
    val frameMs: Int,
    val epoch: Int,
    val resumeToken: String,
    val graceMs: Int,
    val resumed: Boolean,
) {
    companion object {
        fun from(json: JSONObject): SessionReady = SessionReady(
            sessionId = json.str("session_id") ?: throw VolaiException.InvalidResponse("session.ready is missing session_id"),
            uplinkRate = json.optJSONObject("uplink")?.optInt("rate", AudioFrame.UPLINK_RATE) ?: AudioFrame.UPLINK_RATE,
            downlinkRate = json.optJSONObject("downlink")?.optInt("rate", AudioFrame.DOWNLINK_RATE) ?: AudioFrame.DOWNLINK_RATE,
            frameMs = json.optJSONObject("downlink")?.optInt("frame_ms", AudioFrame.FRAME_MS) ?: AudioFrame.FRAME_MS,
            epoch = json.optInt("epoch", 0) and 0xff,
            resumeToken = json.str("resume_token") ?: throw VolaiException.InvalidResponse("session.ready is missing resume_token"),
            graceMs = json.optInt("grace_ms", 15_000),
            resumed = json.optBoolean("resumed", false),
        )
    }
}

/** Inputs for POST /sessions. Only the fields you set are sent. */
data class SessionRequest(
    val agentId: String,
    val deviceId: String? = null,
    val callerName: String? = null,
    val callerPhone: String? = null,
    val callerEmail: String? = null,
    val context: Map<String, Any?>? = null,
    val verificationTokens: Map<String, Any?>? = null,
    val sessionGrant: String? = null,
    val publicLinkPassword: String? = null,
) {
    internal fun body(type: String, transport: String?): JSONObject {
        val body = JSONObject().put("agent_id", agentId).put("type", type)
        transport?.let { body.put("transport", it) }
        deviceId?.let { body.put("device_id", it) }
        callerName?.let { body.put("caller_name", it) }
        callerPhone?.let { body.put("caller_phone", it) }
        callerEmail?.let { body.put("caller_email", it) }
        context?.let { body.put("context", JSONObject(it)) }
        verificationTokens?.let { body.put("verification_tokens", JSONObject(it)) }
        sessionGrant?.let { body.put("session_grant", it) }
        publicLinkPassword?.let { body.put("public_link_password", it) }
        return body
    }
}

/** Builds the reconnect URL from the original socket URL (same host and path, new query). */
internal fun resumeUrl(wsUrl: String, sessionId: String, resumeToken: String): String {
    val base = wsUrl.substringBefore('?')
    return "$base?resume_session=${java.net.URLEncoder.encode(sessionId, "UTF-8")}&resume_token=${java.net.URLEncoder.encode(resumeToken, "UTF-8")}"
}
