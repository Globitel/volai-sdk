package com.globitel.volai

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Entry point: REST side of the Volai SDK contract (docs/openapi.yaml).
 *
 * One OkHttpClient serves the REST calls, the chat event stream and the voice
 * WebSocket, with a cookie jar so the production load balancer's affinity
 * cookie is sent on the socket and on reconnects (docs/voice-ws-protocol.md).
 */
class VolaiClient(
    baseUrl: String,
    val appKey: String,
    val sdkName: String = "volai-android",
    val sdkVersion: String = SDK_VERSION,
    httpClient: OkHttpClient? = null,
) {
    val baseUrl: String = baseUrl.trimEnd('/')
    val http: OkHttpClient = httpClient ?: OkHttpClient.Builder()
        .cookieJar(MemoryCookieJar())
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS) // streaming responses and sockets
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    companion object {
        const val SDK_VERSION = "0.1.1"
        private val JSON = "application/json; charset=utf-8".toMediaType()

        /** Optional diagnostics sink (never receives credentials or audio). */
        @Volatile
        var debugLog: ((String) -> Unit)? = null
        internal fun debug(message: () -> String) { debugLog?.invoke(message()) }
    }

    /** Calls `/gicc/api/sdk/v1{path}`; throws [VolaiException.Api] on non-2xx. */
    suspend fun request(path: String, method: String = "GET", key: String? = null, body: JSONObject? = null): JSONObject =
        withContext(Dispatchers.IO) {
            val builder = Request.Builder()
                .url("$baseUrl/gicc/api/sdk/v1$path")
                .header("Accept", "application/json")
                .header("User-Agent", "$sdkName/$sdkVersion")
                .header("Authorization", "Bearer ${key ?: appKey}")
            when (method) {
                "GET" -> builder.get()
                else -> builder.method(method, (body?.toString() ?: "{}").toRequestBody(JSON))
            }
            debug { "$method $path" }
            http.newCall(builder.build()).execute().use { response ->
                val text = response.body?.string() ?: ""
                debug { "$method $path -> ${response.code} (${text.length} bytes)" }
                val json = try { JSONObject(text) } catch (_: Exception) { JSONObject() }
                if (!response.isSuccessful) {
                    throw VolaiException.Api(
                        response.code,
                        json.optString("message").ifEmpty { response.message.ifEmpty { "HTTP ${response.code}" } },
                        json.optString("code").ifEmpty { null },
                        json.optString("reason").ifEmpty { null },
                    )
                }
                json
            }
        }

    suspend fun getAgent(agentId: String): PublicAgent = PublicAgent(request("/agents/$agentId"))

    suspend fun sendVerificationCode(agentId: String, channel: String, destination: String, language: String? = null) {
        val body = JSONObject().put("channel", channel).put("destination", destination)
        language?.let { body.put("language", it) }
        request("/agents/$agentId/verification/send", "POST", body = body)
    }

    /** Returns the verification token to pass in [SessionRequest.verificationTokens]. */
    suspend fun checkVerificationCode(agentId: String, channel: String, destination: String, code: String): String {
        val json = request("/agents/$agentId/verification/check", "POST",
            body = JSONObject().put("channel", channel).put("destination", destination).put("code", code))
        return json.optString("verification_token").ifEmpty { throw VolaiException.InvalidResponse("verification check returned no token") }
    }

    suspend fun createChat(input: SessionRequest): ChatSession =
        ChatSession(this, ChatSessionInfo(request("/sessions", "POST", body = input.body("chat", null))))

    /** Creates a voice session on the ws_audio transport and returns a call ready to [VoiceCall.connect]. */
    suspend fun createVoice(input: SessionRequest, mode: VoiceCall.Mode = VoiceCall.Mode.FULL_DUPLEX): VoiceCall {
        val info = VoiceSessionInfo(request("/sessions", "POST", body = input.body("voice", "ws_audio")))
        if (info.transport != "ws_audio") throw VolaiException.UnsupportedTransport(info.transport)
        return VoiceCall(info, mode, http, sdkName, sdkVersion)
    }
}

/** In-memory cookie jar: keeps the load balancer's affinity cookie for the client's lifetime. */
internal class MemoryCookieJar : CookieJar {
    private val store = HashMap<String, MutableMap<String, Cookie>>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        synchronized(store) {
            val forHost = store.getOrPut(url.host) { HashMap() }
            for (cookie in cookies) forHost[cookie.name] = cookie
        }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> = synchronized(store) {
        val now = System.currentTimeMillis()
        store[url.host]?.values?.filter { it.expiresAt > now && it.matches(url) }?.toList() ?: emptyList()
    }
}
