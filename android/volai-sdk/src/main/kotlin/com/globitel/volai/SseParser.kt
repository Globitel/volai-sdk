package com.globitel.volai

import org.json.JSONObject

/**
 * Incremental server-sent-events parser. Feed it lines (with or without the
 * trailing newline); it emits one JSONObject per event. Volai sends one JSON
 * object per `data:` line, so an event is emitted as soon as its data parses
 * and also when a new event starts (`id:`, `event:`, comment) or on a blank
 * separator line. `lastId` tracks the cursor for reconnects.
 */
class SseParser(private val onEvent: (JSONObject) -> Unit) {
    var lastId: String? = null
        private set
    private val data = StringBuilder()

    fun feed(rawLine: String) {
        val line = rawLine.trimEnd('\r', '\n')
        when {
            line.isEmpty() -> dispatch()
            line.startsWith("id:") -> { dispatch(); lastId = line.substring(3).trim() }
            line.startsWith("event:") || line.startsWith(":") -> dispatch()
            line.startsWith("data:") -> {
                data.append(line.substring(5).trim())
                dispatch()
            }
        }
    }

    fun finish() = dispatch()

    private fun dispatch() {
        if (data.isEmpty()) return
        val text = data.toString()
        val obj = try { JSONObject(text) } catch (_: Exception) { return }
        data.setLength(0)
        onEvent(obj)
    }
}
