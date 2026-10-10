import Flutter
import Foundation

/// Flutter bridge over the VolaiSDK sources vendored in volai_sdk/Sources/volai_sdk/VolaiSDK
/// (scripts/sync-native.sh). Methods on `com.globitel.volai/sdk`, events on
/// `com.globitel.volai/events` as maps with `kind` = chat | voice.
public final class VolaiSdkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var client: VolaiClient?
    private var chats: [String: VolaiChatSession] = [:]
    private var chatPumps: [String: Task<Void, Never>] = [:]
    private var calls: [String: VolaiVoiceCall] = [:]
    private var callPumps: [String: Task<Void, Never>] = [:]
    private var sink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = VolaiSdkPlugin()
        let methods = FlutterMethodChannel(name: "com.globitel.volai/sdk", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: methods)
        let events = FlutterEventChannel(name: "com.globitel.volai/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(plugin)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func emit(_ body: [String: Any]) {
        DispatchQueue.main.async { self.sink?(body) }
    }

    private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    private func fail(_ result: @escaping FlutterResult, _ error: Error) {
        let flutterError: FlutterError
        if case let VolaiError.api(status, message, code, reason) = error {
            flutterError = FlutterError(code: code ?? "api_\(status)", message: message, details: ["status": status as Any, "reason": (reason as Any?) ?? NSNull()] as [String: Any])
        } else {
            flutterError = FlutterError(code: "volai_error", message: error.localizedDescription, details: nil)
        }
        DispatchQueue.main.async { result(flutterError) }
    }

    private static func sessionRequest(_ dict: [String: Any]) -> SessionRequest {
        SessionRequest(
            agentId: dict["agentId"] as? String ?? "",
            deviceId: dict["deviceId"] as? String,
            callerName: dict["callerName"] as? String,
            callerPhone: dict["callerPhone"] as? String,
            callerEmail: dict["callerEmail"] as? String,
            context: dict["context"] as? [String: Any],
            verificationTokens: dict["verificationTokens"] as? [String: Any],
            sessionGrant: dict["sessionGrant"] as? String,
            publicLinkPassword: dict["publicLinkPassword"] as? String
        )
    }

    private static func readyDict(_ r: SessionReady) -> [String: Any] {
        ["session_id": r.sessionId, "epoch": Int(r.epoch), "resume_token": r.resumeToken, "grace_ms": r.graceMs, "resumed": r.resumed,
         "uplink": ["rate": r.uplinkRate, "frame_ms": r.frameMs], "downlink": ["rate": r.downlinkRate, "frame_ms": r.frameMs]]
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let base = args["baseUrl"] as? String, let url = URL(string: base), let key = args["appKey"] as? String else {
                result(FlutterError(code: "bad_args", message: "baseUrl and appKey are required", details: nil)); return
            }
            client = VolaiClient(baseURL: url, appKey: key, sdkName: "volai-flutter")
            result(nil)
        case "getAgent":
            guard let client = requireClient(result), let agentId = args["agentId"] as? String else { return }
            Task { do { reply(result, try await client.getAgent(agentId).json.raw) } catch { fail(result, error) } }
        case "createChat":
            guard let client = requireClient(result) else { return }
            let request = Self.sessionRequest(args["request"] as? [String: Any] ?? [:])
            Task {
                do {
                    let chat = try await client.createChat(request)
                    chats[chat.info.sessionId] = chat
                    var greeting: Any = NSNull()
                    if let g = chat.info.initialGreeting { greeting = ["id": g.id, "content": g.content] }
                    reply(result, ["sessionId": chat.info.sessionId, "chatToken": chat.info.chatToken, "eventsUrl": chat.info.eventsURL.absoluteString, "initialGreeting": greeting])
                } catch { fail(result, error) }
            }
        case "startChat":
            guard let chat = requireChat(args, result) else { return }
            let sessionId = chat.info.sessionId
            if chatPumps[sessionId] == nil {
                chatPumps[sessionId] = Task { [weak self] in
                    for await event in chat.events {
                        self?.emit(["kind": "chat", "sessionId": sessionId, "event": event.raw])
                    }
                }
            }
            chat.start()
            result(nil)
        case "sendChatMessage":
            guard let chat = requireChat(args, result), let content = args["content"] as? String else { return }
            let messageId = args["messageId"] as? String ?? UUID().uuidString
            Task { do { reply(result, try await chat.send(content, messageId: messageId)) } catch { fail(result, error) } }
        case "ackChatMessage":
            guard let chat = requireChat(args, result), let messageId = args["messageId"] as? String, let status = args["status"] as? String else { return }
            Task { do { try await chat.acknowledge(messageId: messageId, status: status); reply(result, nil) } catch { fail(result, error) } }
        case "chatTyping":
            guard let chat = requireChat(args, result) else { return }
            Task { do { try await chat.typing(); reply(result, nil) } catch { fail(result, error) } }
        case "closeChat":
            guard let sessionId = args["sessionId"] as? String, let chat = chats.removeValue(forKey: sessionId) else { result(nil); return }
            chatPumps.removeValue(forKey: sessionId)?.cancel()
            Task { await chat.close(); reply(result, nil) }
        case "createVoice":
            guard let client = requireClient(result) else { return }
            let request = Self.sessionRequest(args["request"] as? [String: Any] ?? [:])
            let mode: VolaiVoiceCall.Mode = (args["mode"] as? String) == "half_duplex" ? .halfDuplex : .fullDuplex
            Task {
                do {
                    let voice = try await client.createVoice(request, mode: mode)
                    let callId = UUID().uuidString
                    calls[callId] = voice
                    callPumps[callId] = Task { [weak self] in
                        for await event in voice.events {
                            self?.emit(Self.voiceEvent(callId, event))
                        }
                        self?.calls.removeValue(forKey: callId)
                        self?.callPumps.removeValue(forKey: callId)
                    }
                    reply(result, ["callId": callId, "sessionId": voice.info.sessionId, "transport": voice.info.transport, "wsUrl": voice.info.wsURL.absoluteString, "wsTokenExpiresIn": voice.info.wsTokenExpiresIn])
                } catch { fail(result, error) }
            }
        case "connectVoice":
            guard let voice = requireCall(args, result) else { return }
            Task { do { reply(result, Self.readyDict(try await voice.connect())) } catch { fail(result, error) } }
        case "setVoiceMuted":
            guard let voice = requireCall(args, result) else { return }
            voice.setMuted(args["muted"] as? Bool ?? false)
            result(nil)
        case "setVoicePlaybackMuted":
            guard let voice = requireCall(args, result) else { return }
            voice.setPlaybackMuted(args["muted"] as? Bool ?? false)
            result(nil)
        case "endVoice":
            guard let voice = requireCall(args, result) else { return }
            voice.end(reason: args["reason"] as? String ?? "user_hangup")
            result(nil)
        case "setSocketUrlOverride":
            guard let voice = requireCall(args, result) else { return }
            voice.socketURLOverride = (args["url"] as? String).flatMap(URL.init(string:))
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requireClient(_ result: FlutterResult) -> VolaiClient? {
        guard let client else { result(FlutterError(code: "not_configured", message: "Create a VolaiClient first", details: nil)); return nil }
        return client
    }

    private func requireChat(_ args: [String: Any], _ result: FlutterResult) -> VolaiChatSession? {
        guard let sessionId = args["sessionId"] as? String, let chat = chats[sessionId] else {
            result(FlutterError(code: "unknown_session", message: "No chat session \(args["sessionId"] ?? "")", details: nil)); return nil
        }
        return chat
    }

    private func requireCall(_ args: [String: Any], _ result: FlutterResult) -> VolaiVoiceCall? {
        guard let callId = args["callId"] as? String, let voice = calls[callId] else {
            result(FlutterError(code: "unknown_call", message: "No voice call \(args["callId"] ?? "")", details: nil)); return nil
        }
        return voice
    }

    private static func voiceEvent(_ callId: String, _ event: VolaiVoiceCall.Event) -> [String: Any] {
        var body: [String: Any] = ["kind": "voice", "callId": callId]
        switch event {
        case .ready(let r): body["type"] = "ready"; body["ready"] = readyDict(r)
        case .state(let s): body["type"] = "state"; body["state"] = s.rawValue
        case let .transcript(side, text, raw): body["type"] = "transcript"; body["side"] = side; body["text"] = text; body["raw"] = raw.raw
        case .agentSpeaking(let on): body["type"] = "agentSpeaking"; body["speaking"] = on
        case let .interrupted(epoch, reason): body["type"] = "interrupted"; body["epoch"] = Int(epoch); body["reason"] = reason
        case .system(let content): body["type"] = "system"; body["content"] = content
        case .message(let raw): body["type"] = "message"; body["raw"] = raw.raw
        case let .error(code, message, fatal): body["type"] = "error"; body["code"] = (code as Any?) ?? NSNull(); body["message"] = message; body["fatal"] = fatal
        case .ended(let reason): body["type"] = "ended"; body["reason"] = reason
        }
        return body
    }
}
