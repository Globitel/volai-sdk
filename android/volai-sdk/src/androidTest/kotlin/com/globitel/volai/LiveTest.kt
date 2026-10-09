package com.globitel.volai

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Rule
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end tests against a running Volai environment, skipped unless the
 * instrumentation arguments are given:
 *
 *   ./gradlew :volai-sdk:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.volaiBaseUrl=http://10.0.2.2:3007 \
 *     -Pandroid.testInstrumentationRunnerArguments.volaiWsBase=ws://10.0.2.2:8085 \
 *     -Pandroid.testInstrumentationRunnerArguments.volaiAppKey=... \
 *     -Pandroid.testInstrumentationRunnerArguments.volaiAgent=...
 *
 * `volaiWsBase` rewrites the socket origin for development stacks whose
 * WebSocket server runs on another port (10.0.2.2 is the emulator's host).
 */
@RunWith(AndroidJUnit4::class)
class LiveTest {
    @get:Rule
    val microphone: GrantPermissionRule = GrantPermissionRule.grant(android.Manifest.permission.RECORD_AUDIO)

    private val args = InstrumentationRegistry.getArguments()
    private val baseUrl = args.getString("volaiBaseUrl")
    private val appKey = args.getString("volaiAppKey")
    private val agent = args.getString("volaiAgent")
    private val wsBase = args.getString("volaiWsBase")

    @Test
    fun chatRoundTrip() = runBlocking {
        assumeTrue("volai* instrumentation arguments not set", baseUrl != null && appKey != null && agent != null)
        VolaiClient.debugLog = { android.util.Log.i("VolaiLive", it) }
        val client = VolaiClient(baseUrl!!, appKey!!)
        val info = client.getAgent(agent!!)
        assertTrue(info.name.isNotEmpty())
        val chat = client.createChat(SessionRequest(agentId = agent, deviceId = "android-live-test"))
        chat.start()
        val reply = launch {
            withTimeout(40_000) { chat.events.first { it.optString("type") in setOf("chat", "chat_complete") } }
        }
        chat.send("Hello, what can you help me with?")
        reply.join()
        chat.close()
    }

    @Test
    fun voiceGreetingOverWsAudio() = runBlocking {
        assumeTrue("volai* instrumentation arguments not set", baseUrl != null && appKey != null && agent != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val client = VolaiClient(baseUrl!!, appKey!!)
        val call = client.createVoice(SessionRequest(agentId = agent!!, deviceId = "android-live-test"))
        assertEquals("ws_audio", call.info.transport)
        wsBase?.let { call.socketUrlOverride = call.info.wsUrl.replace(Regex("^wss?://[^/]+"), it) }
        var transcripts = 0
        var sawSpeaking = false
        val collector = launch {
            call.events.collect { event ->
                when (event) {
                    is VoiceCall.Event.Transcript -> transcripts++
                    is VoiceCall.Event.AgentSpeaking -> if (event.speaking) sawSpeaking = true
                    else -> Unit
                }
            }
        }
        val ready = call.connect(context)
        assertEquals(24_000, ready.downlinkRate)
        delay(12_000)
        call.end()
        collector.cancel()
        assertTrue("expected the greeting (transcript or speakStart) within 12 s", transcripts > 0 || sawSpeaking)
    }
}
