import Foundation
import React

/// React Native bridge over the VolaiSDK sources vendored in ios/VolaiSDK
/// (scripts/sync-native.sh). Promise-based methods; events on
/// `VolaiChatEvent` and `VolaiVoiceEvent`.
@objc(VolaiSdk)
final class VolaiSdkModule: RCTEventEmitter {
    private var client: VolaiClient?
    private var chats: [String: VolaiChatSession] = [:]
    private var chatPumps: [String: Task<Void, Never>] = [:]
    private var calls: [String: VolaiVoiceCall] = [:]
    private var callPumps: [String: Task<Void, Never>] = [:]
    private var listening = false

    override static func requiresMainQueueSetup() -> Bool { false }
    override func supportedEvents() -> [String] { ["VolaiChatEvent", "VolaiVoiceEvent"] }
    override func startObserving() { listening = true }
    override func stopObserving() { listening = false }

    private func emit(_ name: String, _ body: [String: Any]) {
        if listening { sendEvent(withName: name, body: body) }
    }

    private func fail(_ reject: RCTPromiseRejectBlock, _ error: Error) {
        if case let VolaiError.api(status, message, code, reason) = error {
            reject(code ?? "api_\(status)", message, NSError(domain: "VolaiSdk", code: status, userInfo: ["reason": reason ?? ""]))
        } else {
            reject("volai_error", error.localizedDescription, error)
        }
    }

    private func requireClient(_ reject: RCTPromiseRejectBlock) -> VolaiClient? {
        guard let client else { reject("not_configured", "Call configure(baseUrl, appKey) first", nil); return nil }
        return client
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

    // MARK: - Client

    @objc func configure(_ baseUrl: String, appKey: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let url = URL(string: baseUrl) else { reject("bad_url", "baseUrl is not a URL", nil); return }
        client = VolaiClient(baseURL: url, appKey: appKey, sdkName: "volai-react-native")
        resolve(nil)
    }

    @objc func getAgent(_ agentId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let client = requireClient(reject) else { return }
        Task {
            do { resolve(try await client.getAgent(agentId).json.raw) } catch { fail(reject, error) }
        }
    }

    // MARK: - Chat

    @objc func createChat(_ request: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let client = requireClient(reject) else { return }
        Task {
            do {
                let chat = try await client.createChat(Self.sessionRequest(request))
                chats[chat.info.sessionId] = chat
                var greeting: Any = NSNull()
                if let g = chat.info.initialGreeting { greeting = ["id": g.id, "content": g.content] }
                resolve(["sessionId": chat.info.sessionId, "chatToken": chat.info.chatToken, "eventsUrl": chat.info.eventsURL.absoluteString, "initialGreeting": greeting])
            } catch { fail(reject, error) }
        }
    }

    @objc func startChat(_ sessionId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let chat = chats[sessionId] else { reject("unknown_session", "No chat session \(sessionId)", nil); return }
        if chatPumps[sessionId] == nil {
            chatPumps[sessionId] = Task { [weak self] in
                for await event in chat.events {
                    self?.emit("VolaiChatEvent", ["sessionId": sessionId, "event": event.raw])
                }
            }
        }
        chat.start()
        resolve(nil)
    }

    @objc func sendChatMessage(_ sessionId: String, content: String, messageId: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let chat = chats[sessionId] else { reject("unknown_session", "No chat session \(sessionId)", nil); return }
        Task {
            do { resolve(try await chat.send(content, messageId: messageId ?? UUID().uuidString)) } catch { fail(reject, error) }
        }
    }

    @objc func ackChatMessage(_ sessionId: String, messageId: String, status: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let chat = chats[sessionId] else { reject("unknown_session", "No chat session \(sessionId)", nil); return }
        Task { do { try await chat.acknowledge(messageId: messageId, status: status); resolve(nil) } catch { fail(reject, error) } }
    }

    @objc func chatTyping(_ sessionId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let chat = chats[sessionId] else { reject("unknown_session", "No chat session \(sessionId)", nil); return }
        Task { do { try await chat.typing(); resolve(nil) } catch { fail(reject, error) } }
    }

    @objc func closeChat(_ sessionId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let chat = chats.removeValue(forKey: sessionId) else { resolve(nil); return }
        chatPumps.removeValue(forKey: sessionId)?.cancel()
        Task { await chat.close(); resolve(nil) }
    }

    // MARK: - Voice

    @objc func createVoice(_ request: [String: Any], mode: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let client = requireClient(reject) else { return }
        Task {
            do {
                let call = try await client.createVoice(Self.sessionRequest(request), mode: mode == "half_duplex" ? .halfDuplex : .fullDuplex)
                let callId = UUID().uuidString
                calls[callId] = call
                callPumps[callId] = Task { [weak self] in
                    for await event in call.events {
                        self?.emit("VolaiVoiceEvent", Self.voiceEvent(callId, event))
                    }
                    self?.calls.removeValue(forKey: callId)
                    self?.callPumps.removeValue(forKey: callId)
                }
                resolve(["callId": callId, "sessionId": call.info.sessionId, "transport": call.info.transport, "wsUrl": call.info.wsURL.absoluteString, "wsTokenExpiresIn": call.info.wsTokenExpiresIn])
            } catch { fail(reject, error) }
        }
    }

    @objc func connectVoice(_ callId: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let call = calls[callId] else { reject("unknown_call", "No voice call \(callId)", nil); return }
        Task { do { resolve(Self.readyDict(try await call.connect())) } catch { fail(reject, error) } }
    }

    @objc func setVoiceMuted(_ callId: String, muted: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        calls[callId]?.setMuted(muted)
        resolve(nil)
    }

    @objc func setVoicePlaybackMuted(_ callId: String, muted: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        calls[callId]?.setPlaybackMuted(muted)
        resolve(nil)
    }

    @objc func endVoice(_ callId: String, reason: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        calls[callId]?.end(reason: reason)
        resolve(nil)
    }

    @objc func setSocketUrlOverride(_ callId: String, url: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let call = calls[callId] else { reject("unknown_call", "No voice call \(callId)", nil); return }
        call.socketURLOverride = url.flatMap(URL.init(string:))
        resolve(nil)
    }

    private static func voiceEvent(_ callId: String, _ event: VolaiVoiceCall.Event) -> [String: Any] {
        var body: [String: Any] = ["callId": callId]
        switch event {
        case .ready(let r): body["type"] = "ready"; body["ready"] = readyDict(r)
        case .state(let s): body["type"] = "state"; body["state"] = s.rawValue
        case let .transcript(side, text, raw): body["type"] = "transcript"; body["side"] = side; body["text"] = text; body["raw"] = raw.raw
        case .agentSpeaking(let on): body["type"] = "agentSpeaking"; body["speaking"] = on
        case let .interrupted(epoch, reason): body["type"] = "interrupted"; body["epoch"] = Int(epoch); body["reason"] = reason
        case .system(let content): body["type"] = "system"; body["content"] = content
        case .message(let raw): body["type"] = "message"; body["raw"] = raw.raw
        case let .error(code, message, fatal): body["type"] = "error"; body["code"] = code ?? NSNull(); body["message"] = message; body["fatal"] = fatal
        case .ended(let reason): body["type"] = "ended"; body["reason"] = reason
        }
        return body
    }
}
