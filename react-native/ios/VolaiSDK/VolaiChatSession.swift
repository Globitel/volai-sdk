import Foundation

/// A chat session: messages over REST, events over server-sent events.
/// The event stream reconnects with the last cursor until `close()`.
public final class VolaiChatSession {
    public let info: ChatSessionInfo
    private let client: VolaiClient
    private var task: Task<Void, Never>?
    private var cursor: String?
    private(set) public var isClosed = false
    private var continuation: AsyncStream<JSONObject>.Continuation?

    /// Every event the server sends (`chat`, `chunk`, `chat_complete`, `human_chat`, `typing`,
    /// `system`, `LIVE_AGENT_CONNECTED`, `LIVE_AGENT_DISCONNECTED`, `SESSION_ENDED`, `error`, ...).
    public let events: AsyncStream<JSONObject>

    init(client: VolaiClient, info: ChatSessionInfo) {
        self.client = client
        self.info = info
        var cont: AsyncStream<JSONObject>.Continuation?
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Opens the event stream. Idempotent.
    public func start() {
        guard task == nil, !isClosed else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !self.isClosed, !Task.isCancelled {
                do {
                    try await self.pumpOnce()
                } catch {
                    if self.isClosed || Task.isCancelled { return }
                    self.continuation?.yield(JSONObject(["type": "stream_error", "message": error.localizedDescription]))
                }
                if !self.isClosed { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
    }

    private func pumpOnce() async throws {
        var components = URLComponents(url: info.eventsURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "chat_token", value: info.chatToken))
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        var req = URLRequest(url: components.url!)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 3600
        VolaiClient.debug("chat events: connecting (cursor=\(cursor ?? "none"))")
        let (bytes, response) = try await client.session.bytes(for: req)
        VolaiClient.debug("chat events: status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 404 {
            isClosed = true
            continuation?.yield(JSONObject(["type": "SESSION_ENDED", "reason": "token_rejected"]))
            continuation?.finish()
            return
        }
        // AsyncLineSequence drops empty lines, so the SSE event separator is
        // never seen. Volai sends one JSON object per event: dispatch as soon
        // as the accumulated data parses, and also when a new event starts.
        var data = ""
        func dispatch() -> Bool {
            guard !data.isEmpty, let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return false }
            data = ""
            let event = JSONObject(obj)
            continuation?.yield(event)
            if event.string("type") == "SESSION_ENDED" {
                isClosed = true
                continuation?.finish()
                return true
            }
            return false
        }
        for try await line in bytes.lines {
            if line.hasPrefix("id:") {
                if dispatch() { return }
                cursor = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("event:") || line.hasPrefix(":") {
                if dispatch() { return }
            } else if line.hasPrefix("data:") {
                data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dispatch() { return }
            }
        }
        _ = dispatch()
    }

    /// Sends a user message. Returns the message id (generated when not given).
    @discardableResult
    public func send(_ content: String, messageId: String = UUID().uuidString, attachment: [String: Any]? = nil) async throws -> String {
        var body: [String: Any] = ["message_id": messageId, "content": content]
        if let attachment { body["attachment"] = attachment }
        try await client.request("/sessions/\(info.sessionId)/messages", method: "POST", key: info.chatToken, body: body)
        return messageId
    }

    public func acknowledge(messageId: String, status: String) async throws {
        try await client.request("/sessions/\(info.sessionId)/acks", method: "POST", key: info.chatToken,
                                 body: ["message_id": messageId, "status": status])
    }

    public func typing() async throws {
        try await client.request("/sessions/\(info.sessionId)/typing", method: "POST", key: info.chatToken)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel()
        task = nil
        _ = try? await client.request("/sessions/\(info.sessionId)/close", method: "POST", key: info.chatToken)
        continuation?.finish()
    }
}
