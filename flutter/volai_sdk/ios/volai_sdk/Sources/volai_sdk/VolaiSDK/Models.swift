import Foundation

/// Error raised by the REST layer and by the voice socket.
public enum VolaiError: Error, LocalizedError {
    /// The server answered with a non-2xx status. `code` and `reason` are the
    /// contract's machine-readable fields when present.
    case api(status: Int, message: String, code: String?, reason: String?)
    case transport(String)
    case unsupportedTransport(String)
    case invalidResponse(String)
    case microphoneDenied

    public var errorDescription: String? {
        switch self {
        case let .api(status, message, _, _): return "Volai API \(status): \(message)"
        case let .transport(message): return message
        case let .unsupportedTransport(transport): return "Server picked transport \"\(transport)\", which this SDK does not implement"
        case let .invalidResponse(message): return "Invalid response: \(message)"
        case .microphoneDenied: return "Microphone access was denied"
        }
    }
}

/// Lenient JSON access for contract objects whose field sets grow over time.
public struct JSONObject: Equatable {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]) { self.raw = raw }

    public subscript(key: String) -> Any? { raw[key] }
    public func string(_ key: String) -> String? { raw[key] as? String }
    public func int(_ key: String) -> Int? {
        if let v = raw[key] as? Int { return v }
        if let v = raw[key] as? Double { return Int(v) }
        if let v = raw[key] as? String { return Int(v) }
        return nil
    }
    public func bool(_ key: String) -> Bool? { raw[key] as? Bool }
    public func object(_ key: String) -> JSONObject? { (raw[key] as? [String: Any]).map(JSONObject.init) }
    public func strings(_ key: String) -> [String]? { raw[key] as? [String] }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        NSDictionary(dictionary: lhs.raw).isEqual(to: rhs.raw)
    }
}

/// Public agent information (GET /agents/{id}).
public struct PublicAgent {
    public let apiId: String
    public let name: String
    public let architecture: String?
    public let embedMode: String
    public let voiceTransports: [String]
    public let defaultVoiceTransport: String
    public let publicLinkPasswordRequired: Bool
    public let json: JSONObject

    init(json: JSONObject) throws {
        guard let apiId = json.string("api_id"), let name = json.string("name") else {
            throw VolaiError.invalidResponse("agent lookup is missing api_id or name")
        }
        self.apiId = apiId
        self.name = name
        self.architecture = json.string("agentArchitecture")
        self.embedMode = json.string("embedMode") ?? "both"
        self.voiceTransports = json.strings("voiceTransports") ?? ["webrtc"]
        self.defaultVoiceTransport = json.string("defaultVoiceTransport") ?? "webrtc"
        self.publicLinkPasswordRequired = json.bool("publicLinkPasswordRequired") ?? false
        self.json = json
    }
}

public struct VoiceSessionInfo {
    public let sessionId: String
    public let transport: String
    public let wsURL: URL
    public let wsToken: String
    public let wsTokenExpiresIn: Int

    init(json: JSONObject) throws {
        guard let sessionId = json.string("session_id"), let transport = json.string("transport"),
              let ws = json.string("ws_url"), let url = URL(string: ws), let token = json.string("ws_token") else {
            throw VolaiError.invalidResponse("voice session is missing session_id, transport, ws_url or ws_token")
        }
        self.sessionId = sessionId
        self.transport = transport
        self.wsURL = url
        self.wsToken = token
        self.wsTokenExpiresIn = json.int("ws_token_expires_in") ?? 30
    }
}

public struct ChatSessionInfo {
    public let sessionId: String
    public let chatToken: String
    public let eventsURL: URL
    public let initialGreeting: (id: String, content: String)?
    public let idleMinutes: Int?
    public let expiresAt: String?

    init(json: JSONObject) throws {
        guard let sessionId = json.string("session_id"), let token = json.string("chat_token"),
              let events = json.string("events_url"), let url = URL(string: events) else {
            throw VolaiError.invalidResponse("chat session is missing session_id, chat_token or events_url")
        }
        self.sessionId = sessionId
        self.chatToken = token
        self.eventsURL = url
        if let g = json.object("initial_greeting"), let id = g.string("id"), let content = g.string("content") {
            self.initialGreeting = (id, content)
        } else {
            self.initialGreeting = nil
        }
        self.idleMinutes = json.int("idle_minutes")
        self.expiresAt = json.string("expires_at")
    }
}

/// `session.ready` from the voice socket.
public struct SessionReady: Equatable {
    public let sessionId: String
    public let uplinkRate: Int
    public let downlinkRate: Int
    public let frameMs: Int
    public let epoch: UInt8
    public let resumeToken: String
    public let graceMs: Int
    public let resumed: Bool

    init(json: JSONObject) throws {
        guard let sessionId = json.string("session_id"), let resumeToken = json.string("resume_token") else {
            throw VolaiError.invalidResponse("session.ready is missing session_id or resume_token")
        }
        self.sessionId = sessionId
        self.uplinkRate = json.object("uplink")?.int("rate") ?? AudioFrame.uplinkRate
        self.downlinkRate = json.object("downlink")?.int("rate") ?? AudioFrame.downlinkRate
        self.frameMs = json.object("downlink")?.int("frame_ms") ?? AudioFrame.frameMs
        self.epoch = UInt8(truncatingIfNeeded: json.int("epoch") ?? 0)
        self.resumeToken = resumeToken
        self.graceMs = json.int("grace_ms") ?? 15_000
        self.resumed = json.bool("resumed") ?? false
    }
}

/// Inputs for POST /sessions.
public struct SessionRequest {
    public var agentId: String
    public var deviceId: String?
    public var callerName: String?
    public var callerPhone: String?
    public var callerEmail: String?
    public var context: [String: Any]?
    public var verificationTokens: [String: Any]?
    public var sessionGrant: String?
    public var publicLinkPassword: String?

    public init(agentId: String, deviceId: String? = nil, callerName: String? = nil, callerPhone: String? = nil,
                callerEmail: String? = nil, context: [String: Any]? = nil, verificationTokens: [String: Any]? = nil,
                sessionGrant: String? = nil, publicLinkPassword: String? = nil) {
        self.agentId = agentId
        self.deviceId = deviceId
        self.callerName = callerName
        self.callerPhone = callerPhone
        self.callerEmail = callerEmail
        self.context = context
        self.verificationTokens = verificationTokens
        self.sessionGrant = sessionGrant
        self.publicLinkPassword = publicLinkPassword
    }

    func body(type: String, transport: String?) -> [String: Any] {
        var body: [String: Any] = ["agent_id": agentId, "type": type]
        if let transport { body["transport"] = transport }
        if let deviceId { body["device_id"] = deviceId }
        if let callerName { body["caller_name"] = callerName }
        if let callerPhone { body["caller_phone"] = callerPhone }
        if let callerEmail { body["caller_email"] = callerEmail }
        if let context { body["context"] = context }
        if let verificationTokens { body["verification_tokens"] = verificationTokens }
        if let sessionGrant { body["session_grant"] = sessionGrant }
        if let publicLinkPassword { body["public_link_password"] = publicLinkPassword }
        return body
    }
}

/// Builds the reconnect URL from the original socket URL (same host and path, new query).
func resumeURL(from wsURL: URL, sessionId: String, resumeToken: String) -> URL? {
    guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }
    components.queryItems = [
        URLQueryItem(name: "resume_session", value: sessionId),
        URLQueryItem(name: "resume_token", value: resumeToken),
    ]
    return components.url
}
