package com.globitel.volai

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AttachmentTest {
    @Test
    fun parsesTheEventShapeAndRoundTrips() {
        val event = JSONObject("""{"type":"human_chat","attachment":{"url":"/gicc/uploads/chat/x.png","filename":"x.png","mimetype":"image/png","size":1234}}""")
        val a = ChatAttachment.fromJson(event.optJSONObject("attachment"))!!
        assertEquals("/gicc/uploads/chat/x.png", a.url)
        assertEquals("image/png", a.mimeType)
        assertEquals(1234L, a.size)
        assertEquals("image/png", a.toJson().getString("mimetype"))
        assertNull(ChatAttachment.fromJson(JSONObject("""{"type":"chat"}""").optJSONObject("attachment")))
        assertNull(ChatAttachment.fromJson(JSONObject("""{"url":""}""")))
    }

    @Test
    fun guessesMimeTypesTheServerAccepts() {
        assertEquals("application/pdf", ChatAttachment.guessMimeType("invoice.PDF"))
        assertEquals("image/jpeg", ChatAttachment.guessMimeType("photo.jpeg"))
        assertEquals("text/csv", ChatAttachment.guessMimeType("list.csv"))
        assertEquals("application/octet-stream", ChatAttachment.guessMimeType("archive.zip"))
        assertEquals("application/octet-stream", ChatAttachment.guessMimeType("noext"))
    }
}
