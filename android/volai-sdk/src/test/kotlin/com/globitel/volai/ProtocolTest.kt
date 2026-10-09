package com.globitel.volai

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioFrameTest {
    @Test
    fun roundTripWithWrappingHeaderFields() {
        val pcm = shortArrayOf(1, -2, 32767, -32768, 0)
        val data = AudioFrame.encode(300, 70000, pcm)
        assertEquals(4 + pcm.size * 2, data.size)
        val decoded = AudioFrame.decode(data)!!
        assertEquals(300 and 0xff, decoded.epoch)
        assertEquals(70000 and 0xffff, decoded.seq)
        assertArrayEquals(pcm, decoded.pcm)
        // little-endian payload, big-endian sequence
        assertArrayEquals(byteArrayOf(1, 44, 0x11, 0x70, 0x01, 0x00), data.copyOfRange(0, 6))
    }

    @Test
    fun malformedFramesAreRejected() {
        assertNull("wrong version", AudioFrame.decode(byteArrayOf(2, 0, 0, 0, 1, 1)))
        assertNull("short header", AudioFrame.decode(byteArrayOf(1, 0, 0)))
        assertNull("odd payload", AudioFrame.decode(byteArrayOf(1, 0, 0, 0, 1)))
        assertEquals(0, AudioFrame.decode(byteArrayOf(1, 3, 0, 9))!!.pcm.size)
    }

    @Test
    fun frameSizes() {
        assertEquals(320, AudioFrame.UPLINK_SAMPLES)
        assertEquals(480, AudioFrame.DOWNLINK_SAMPLES)
    }
}

class PlaybackBufferTest {
    @Test
    fun prebufferThenPlaysInOrder() {
        val buffer = PlaybackBuffer(24_000, prebufferMs = 20)
        val out = ShortArray(4)
        assertEquals(0, buffer.pull(out))
        assertTrue(out.all { it == 0.toShort() })
        buffer.push(0, ShortArray(240) { 1000 }) // 10 ms, below prebuffer
        assertEquals(0, buffer.pull(out))
        buffer.push(0, ShortArray(240) { 2000 })
        val big = ShortArray(480)
        assertEquals(480, buffer.pull(big))
        assertEquals(1000.toShort(), big[0])
        assertEquals(2000.toShort(), big[479])
        assertEquals(0, buffer.pull(out))
    }

    @Test
    fun epochDropsStaleFramesAndFlushClearsTheQueue() {
        val buffer = PlaybackBuffer(24_000, prebufferMs = 0)
        buffer.push(0, ShortArray(480) { 1 })
        assertEquals(20, buffer.bufferedMs)
        buffer.flush(1)
        assertEquals(0, buffer.bufferedMs)
        buffer.push(0, ShortArray(480) { 1 })
        assertEquals("frame from the old epoch is dropped", 0, buffer.bufferedMs)
        buffer.push(1, ShortArray(480) { 1 })
        assertEquals(20, buffer.bufferedMs)
        assertEquals(1, buffer.epoch)
    }

    @Test
    fun padsWithSilenceWhenShort() {
        val buffer = PlaybackBuffer(24_000, prebufferMs = 0)
        buffer.push(0, ShortArray(100) { 7 })
        val out = ShortArray(480)
        assertEquals(100, buffer.pull(out))
        assertEquals(7.toShort(), out[99])
        assertEquals(0.toShort(), out[100])
    }
}

class SseParserTest {
    private fun collect(lines: List<String>): List<JSONObject> {
        val events = mutableListOf<JSONObject>()
        val parser = SseParser { events.add(it) }
        lines.forEach(parser::feed)
        parser.finish()
        return events
    }

    @Test
    fun dispatchesEachDataLineAndTracksTheCursor() {
        val events = mutableListOf<JSONObject>()
        val parser = SseParser { events.add(it) }
        listOf("id: 1", "event: chat", "data: {\"type\":\"chat\",\"content\":\"hi\"}", "", ": heartbeat", "id: 2", "data: {\"type\":\"typing\"}").forEach(parser::feed)
        assertEquals(listOf("chat", "typing"), events.map { it.getString("type") })
        assertEquals("2", parser.lastId)
    }

    @Test
    fun ignoresPartialJsonUntilComplete() {
        val events = collect(listOf("data: {\"type\":\"chat\",", "data: \"content\":\"a\"}", ""))
        assertEquals(1, events.size)
        assertEquals("a", events[0].getString("content"))
    }

    @Test
    fun sessionEndedIsDelivered() {
        val events = collect(listOf("data: {\"type\":\"SESSION_ENDED\"}"))
        assertEquals("SESSION_ENDED", events.single().getString("type"))
    }
}

class ModelsTest {
    @Test
    fun sessionReadyParsesTheContractShape() {
        val ready = SessionReady.from(JSONObject("""{"type":"session.ready","session_id":"s1","uplink":{"rate":16000,"frame_ms":20},"downlink":{"rate":24000,"frame_ms":20},"epoch":3,"resume_token":"abc","grace_ms":15000,"resumed":true}"""))
        assertEquals("s1", ready.sessionId)
        assertEquals(3, ready.epoch)
        assertEquals(24000, ready.downlinkRate)
        assertTrue(ready.resumed)
    }

    @Test
    fun resumeUrlKeepsHostAndPath() {
        assertEquals(
            "wss://gicc.globitel.com/gicc/ws/sdk/voice?resume_session=s1&resume_token=r1",
            resumeUrl("wss://gicc.globitel.com/gicc/ws/sdk/voice?token=abc", "s1", "r1"),
        )
    }

    @Test
    fun sessionRequestBodyOnlyCarriesGivenFields() {
        val body = SessionRequest(agentId = "a", deviceId = "d", sessionGrant = "g").body("voice", "ws_audio")
        assertEquals("a", body.getString("agent_id"))
        assertEquals("ws_audio", body.getString("transport"))
        assertEquals("g", body.getString("session_grant"))
        assertFalse(body.has("caller_phone"))
    }

    @Test(expected = VolaiException.InvalidResponse::class)
    fun voiceSessionInfoRejectsMissingFields() {
        VoiceSessionInfo(JSONObject("""{"session_id":"s"}"""))
    }
}
