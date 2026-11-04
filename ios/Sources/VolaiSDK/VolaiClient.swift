import Foundation

/// Entry point: REST side of the Volai SDK contract (docs/openapi.yaml).
///
/// Uses `URLSession.shared` by default, whose cookie storage keeps the
/// production load balancer's affinity cookie and sends it on the voice
/// socket and on reconnects (docs/voice-ws-protocol.md, "Reconnect").
public final class VolaiClient {
    public let baseURL: URL
    public let appKey: String
    public let sdkName: String
    public let sdkVersion: String
    public let session: URLSession

    public static let sdkVersionString = "0.2.1"

    /// Optional diagnostics sink (never logs credentials or audio).
    public static var debugLog: ((String) -> Void)?
    static func debug(_ message: @autoclosure () -> String) { debugLog?(message()) }

    public init(baseURL: URL, appKey: String, sdkName: String = "volai-ios", sdkVersion: String = VolaiClient.sdkVersionString, session: URLSession = .shared) {
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = URL(string: trimmed) ?? baseURL
        self.appKey = appKey
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.session = session
    }

    // MARK: - Low level

    /// Calls `/gicc/api/sdk/v1{path}` and returns the JSON object; throws `VolaiError.api` on non-2xx.
    @discardableResult
    public func request(_ path: String, method: String = "GET", key: String? = nil, body: [String: Any]? = nil) async throws -> JSONObject {
        var url = baseURL
        url.appendPathComponent("gicc/api/sdk/v1" + path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(sdkName)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(key ?? appKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        VolaiClient.debug("\(method) \(path)")
        let (data, response) = try await session.data(for: req)
        return try Self.decode(data, response, method: method, path: path)
    }

    /// Multipart upload (one `file` part) to `/gicc/api/sdk/v1{path}`; throws `VolaiError.api` on non-2xx.
    @discardableResult
    public func upload(_ path: String, key: String? = nil, fileData: Data, filename: String, mimeType: String) async throws -> JSONObject {
        var url = baseURL
        url.appendPathComponent("gicc/api/sdk/v1" + path)
        let boundary = "VolaiBoundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(sdkName)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(key ?? appKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = Self.multipartBody(boundary: boundary, field: "file", filename: filename, mimeType: mimeType, data: fileData)
        VolaiClient.debug("POST \(path) (multipart, \(fileData.count) bytes)")
        let (data, response) = try await session.data(for: req)
        return try Self.decode(data, response, method: "POST", path: path)
    }

    private static func decode(_ data: Data, _ response: URLResponse, method: String, path: String) throws -> JSONObject {
        guard let http = response as? HTTPURLResponse else { throw VolaiError.transport("no HTTP response") }
        VolaiClient.debug("\(method) \(path) -> \(http.statusCode) (\(data.count) bytes)")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw VolaiError.api(status: http.statusCode,
                                 message: json["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                                 code: json["code"] as? String,
                                 reason: json["reason"] as? String)
        }
        return JSONObject(json)
    }

    /// One-part multipart/form-data body (the filename travels as UTF-8, which the server expects).
    static func multipartBody(boundary: String, field: String, filename: String, mimeType: String, data: Data) -> Data {
        let safeName = filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: - Discovery and verification

    public func getAgent(_ agentId: String) async throws -> PublicAgent {
        try PublicAgent(json: try await request("/agents/\(agentId)"))
    }

    public func sendVerificationCode(agentId: String, channel: String, destination: String, language: String? = nil) async throws {
        var body: [String: Any] = ["channel": channel, "destination": destination]
        if let language { body["language"] = language }
        try await request("/agents/\(agentId)/verification/send", method: "POST", body: body)
    }

    /// Returns the verification token to pass in `SessionRequest.verificationTokens`.
    public func checkVerificationCode(agentId: String, channel: String, destination: String, code: String) async throws -> String {
        let json = try await request("/agents/\(agentId)/verification/check", method: "POST",
                                     body: ["channel": channel, "destination": destination, "code": code])
        guard let token = json.string("verification_token") else { throw VolaiError.invalidResponse("verification check returned no token") }
        return token
    }

    // MARK: - Sessions

    public func createChat(_ input: SessionRequest) async throws -> VolaiChatSession {
        let json = try await request("/sessions", method: "POST", body: input.body(type: "chat", transport: nil))
        return VolaiChatSession(client: self, info: try ChatSessionInfo(json: json))
    }

    /// Creates a voice session on the ws_audio transport and returns a call ready to `connect()`.
    public func createVoice(_ input: SessionRequest, mode: VolaiVoiceCall.Mode = .fullDuplex) async throws -> VolaiVoiceCall {
        let json = try await request("/sessions", method: "POST", body: input.body(type: "voice", transport: "ws_audio"))
        let info = try VoiceSessionInfo(json: json)
        guard info.transport == "ws_audio" else { throw VolaiError.unsupportedTransport(info.transport) }
        return VolaiVoiceCall(info: info, mode: mode, sdkName: sdkName, sdkVersion: sdkVersion, session: session)
    }
}
