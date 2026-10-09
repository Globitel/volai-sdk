import XCTest
@testable import VolaiSDK

/// End-to-end tests against a running Volai environment. Skipped unless
/// VOLAI_BASE_URL, VOLAI_APP_KEY and VOLAI_AGENT are set. VOLAI_WS_BASE
/// rewrites the socket origin for development stacks whose WebSocket
/// server runs on another port.
///
///   VOLAI_BASE_URL=http://localhost:3007 VOLAI_WS_BASE=ws://localhost:8085 \
///   VOLAI_APP_KEY=... VOLAI_AGENT=... swift test --filter LiveTests
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data(("[volai] " + message + "\n").utf8))
}

/// Races an async step against a deadline so a hang becomes a located failure.
func withTimeout<T>(_ seconds: Double, _ label: String, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw VolaiError.transport("timeout after \(seconds)s in \(label)")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

final class LiveTests: XCTestCase {
    private var env: (base: URL, key: String, agent: String, wsBase: String?)? {
        let e = ProcessInfo.processInfo.environment
        guard let base = e["VOLAI_BASE_URL"].flatMap(URL.init(string:)), let key = e["VOLAI_APP_KEY"], let agent = e["VOLAI_AGENT"] else { return nil }
        return (base, key, agent, e["VOLAI_WS_BASE"])
    }

    func testChatRoundTrip() async throws {
        guard let env else { throw XCTSkip("VOLAI_* environment not set") }
        VolaiClient.debugLog = { stderrLog($0) }
        stderrLog("chat test start base=\(env.base)")
        let client = VolaiClient(baseURL: env.base, appKey: env.key)
        let agent = try await withTimeout(20, "getAgent") { try await client.getAgent(env.agent) }
        stderrLog("agent ok: \(agent.name)")
        XCTAssertFalse(agent.name.isEmpty)
        let chat = try await withTimeout(30, "createChat") { try await client.createChat(SessionRequest(agentId: env.agent, deviceId: "ios-live-test")) }
        stderrLog("chat created: \(chat.info.sessionId)")
        chat.start()
        try await withTimeout(40, "send") { try await chat.send("Hello, what can you help me with?") }
        stderrLog("message sent")
        var gotReply = false
        let deadline = Date().addingTimeInterval(40)
        for await event in chat.events {
            if ["chat", "chat_complete"].contains(event.string("type") ?? "") { gotReply = true; break }
            if Date() > deadline { break }
        }
        XCTAssertTrue(gotReply, "no agent reply on the event stream")
        await chat.close()
    }

    func testVoiceGreetingOverWsAudio() async throws {
        guard let env else { throw XCTSkip("VOLAI_* environment not set") }
        let client = VolaiClient(baseURL: env.base, appKey: env.key)
        let call = try await client.createVoice(SessionRequest(agentId: env.agent, deviceId: "ios-live-test"))
        XCTAssertEqual(call.info.transport, "ws_audio")
        if let wsBase = env.wsBase {
            // Development only: point the socket at the dev WebSocket port.
            let rewritten = call.info.wsURL.absoluteString.replacingOccurrences(of: "^wss?://[^/]+", with: wsBase, options: .regularExpression)
            try await LiveTests.runCall(client: client, agent: env.agent, deviceId: "ios-live-test", overrideURL: URL(string: rewritten)!)
            return
        }
        try await LiveTests.runCall(call: call)
    }

    private static func runCall(client: VolaiClient, agent: String, deviceId: String, overrideURL: URL) async throws {
        // Re-create the session with the rewritten socket URL (dev stacks only).
        let json = try await client.request("/sessions", method: "POST", body: SessionRequest(agentId: agent, deviceId: deviceId).body(type: "voice", transport: "ws_audio"))
        var raw = json.raw
        raw["ws_url"] = overrideURL.absoluteString.replacingOccurrences(of: "\\?.*$", with: "", options: .regularExpression) + "?" + (URLComponents(string: json.string("ws_url")!)?.query ?? "")
        let info = try VoiceSessionInfo(json: JSONObject(raw))
        let call = VolaiVoiceCall(info: info, mode: .fullDuplex, sdkName: "volai-ios-test", sdkVersion: VolaiClient.sdkVersionString, session: client.session)
        try await runCall(call: call)
    }

    private static func runCall(call: VolaiVoiceCall) async throws {
        let ready = try await call.connect()
        XCTAssertEqual(ready.downlinkRate, 24_000)
        var transcripts = 0
        var sawSpeaking = false
        let deadline = Date().addingTimeInterval(20)
        let collector = Task {
            for await event in call.events {
                switch event {
                case .transcript: transcripts += 1
                case .agentSpeaking(true): sawSpeaking = true
                default: break
                }
                if Date() > deadline { break }
            }
        }
        try await Task.sleep(nanoseconds: 12_000_000_000)
        call.end()
        collector.cancel()
        XCTAssertTrue(transcripts > 0 || sawSpeaking, "expected the greeting (transcript or speakStart) within 12 s")
    }
}
