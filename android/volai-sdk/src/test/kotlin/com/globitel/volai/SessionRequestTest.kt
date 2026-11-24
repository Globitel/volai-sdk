package com.globitel.volai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SessionRequestTest {
    @Test
    fun sendsCapabilitiesAndLanguageOnAChatSession() {
        val body = SessionRequest(agentId = "a", capabilities = listOf("interactive", "forms"), language = "ar").body("chat", null)
        assertEquals("ar", body.getString("language"))
        assertEquals(2, body.getJSONArray("capabilities").length())
        assertEquals("forms", body.getJSONArray("capabilities").getString(1))
    }

    @Test
    fun leavesOutWhatWasNotSet() {
        val body = SessionRequest(agentId = "a").body("chat", null)
        assertFalse(body.has("capabilities"))
        assertFalse(body.has("language"))
        val empty = SessionRequest(agentId = "a", capabilities = emptyList(), language = " ").body("chat", null)
        assertFalse(empty.has("capabilities"))
        assertFalse(empty.has("language"))
    }

    @Test
    fun capabilitiesAreForChatOnly() {
        val body = SessionRequest(agentId = "a", capabilities = listOf("interactive"), language = "en").body("voice", "ws_audio")
        assertFalse(body.has("capabilities"))
        assertEquals("en", body.getString("language"))
    }
}
