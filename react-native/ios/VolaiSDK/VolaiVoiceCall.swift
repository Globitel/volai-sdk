import Foundation

/// One voice call on the ws_audio transport (docs/voice-ws-protocol.md).
///
/// Lifecycle: `connect()` opens the socket, sends `client.hello`, starts
/// playback and capture (the greeting plays while the microphone prompt
/// may still be up), and resolves on `session.ready`. An abnormal socket
/// loss triggers a resume within the server's grace window; a clean close
/// or `end()` finishes the call. Events arrive on `events`.
public final class VolaiVoiceCall {
    public enum Mode: String { case fullDuplex = "full_duplex", halfDuplex = "half_duplex" }
    public enum State: String { case idle, connecting, connected, reconnecting, ended }

    public enum Event {
        case ready(SessionReady)
        case state(State)
        case transcript(side: String, text: String, raw: JSONObject)
        case agentSpeaking(Bool)
        case interrupted(epoch: UInt8, reason: String)
        case system(String)
        case message(JSONObject)
        case error(code: String?, message: String, fatal: Bool)
        case ended(reason: String)
    }

    public let info: VoiceSessionInfo
    public let mode: Mode
    public private(set) var state: State = .idle
    public private(set) var ready: SessionReady?
    public private(set) var muted = false
    public let events: AsyncStream<Event>

    private let sdkName: String
    private let sdkVersion: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private let playback = PlaybackBuffer(sourceRate: AudioFrame.downlinkRate)
    private lazy var audio = VoiceAudioEngine(playback: playback)
    private var seq: UInt16 = 0
    private var ended = false
    private var endRequested = false
    private var reconnectDeadline: Date?
    private var readyContinuation: CheckedContinuation<SessionReady, Error>?
    private let queue = DispatchQueue(label: "com.globitel.volai.voice")
    /// Development only: replaces the socket URL (e.g. a dev stack whose WebSocket server runs on another port).
    public var socketURLOverride: URL?

    init(info: VoiceSessionInfo, mode: Mode, sdkName: String, sdkVersion: String, session: URLSession) {
        self.info = info
        self.mode = mode
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.session = session
        var cont: AsyncStream<Event>.Continuation?
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Public API

    /// Opens the call. Resolves with `session.ready`; throws when the socket or the microphone fails.
    @discardableResult
    public func connect() async throws -> SessionReady {
        guard state == .idle else { throw VolaiError.transport("connect() may only be called once") }
        setState(.connecting)
        let readyValue: SessionReady = try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.readyContinuation = cont
                self.open(url: self.socketURLOverride ?? self.info.wsURL)
            }
        }
        do {
            try audio.start { [weak self] frame in self?.sendUplink(frame) }
        } catch {
            finish(reason: "mic_failed")
            throw error
        }
        return readyValue
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        audio.muted = muted
        send(["type": "mic.muted", "muted": muted])
    }

    /// Silences local playback without stopping the stream.
    public func setPlaybackMuted(_ muted: Bool) {
        audio.playbackMuted = muted
    }

    /// Hangs up: tells the server, then releases the audio session.
    public func end(reason: String = "user_hangup") {
        queue.async {
            guard !self.ended else { return }
            self.endRequested = true
            self.send(["type": "session.end", "reason": reason])
            self.socket?.cancel(with: .normalClosure, reason: Data("end".utf8))
            self.finish(reason: "user_ended")
        }
    }

    // MARK: - Socket

    private func open(url: URL) {
        var req = URLRequest(url: url)
        req.setValue("\(sdkName)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: req)
        socket = task
        task.resume()
        send(["type": "client.hello", "sdk": sdkName, "version": sdkVersion, "platform": "ios", "mode": mode.rawValue])
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        startPing()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data): handleDownlink(data)
                case .string(let text): handleControl(text)
                @unknown default: break
                }
            } catch {
                queue.async { self.onSocketClosed(task: task, error: error) }
                return
            }
        }
    }

    private func onSocketClosed(task: URLSessionWebSocketTask, error: Error) {
        guard task === socket, !ended else { return }
        let code = task.closeCode
        let clean = endRequested || code == .normalClosure || code == .goingAway || code == .policyViolation
        if clean || ready == nil {
            if ready == nil, let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(throwing: VolaiError.transport("voice socket closed before session.ready (\(code.rawValue))"))
            }
            finish(reason: endRequested ? "user_ended" : "socket_closed")
            return
        }
        if state != .reconnecting {
            reconnectDeadline = Date().addingTimeInterval(TimeInterval((ready?.graceMs ?? 15_000) - 1000) / 1000)
            setState(.reconnecting)
        }
        if let deadline = reconnectDeadline, Date() >= deadline {
            finish(reason: "reconnect_failed")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) {
            guard !self.ended, let ready = self.ready,
                  let url = resumeURL(from: self.socketURLOverride ?? self.info.wsURL, sessionId: ready.sessionId, resumeToken: ready.resumeToken) else { return }
            self.open(url: url)
        }
    }

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func sendUplink(_ pcm: [Int16]) {
        guard state == .connected, !muted, let socket else { return }
        let frame = AudioFrame.encode(epoch: 0, seq: seq, pcm: pcm)
        seq &+= 1
        socket.send(.data(frame)) { _ in }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !self.ended else { return }
                self.send(["type": "ping", "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
    }

    // MARK: - Inbound

    private func handleDownlink(_ data: Data) {
        guard let frame = AudioFrame.decode(data) else { return }
        playback.push(epoch: frame.epoch, pcm: frame.pcm)
    }

    private func handleControl(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let json = JSONObject(obj)
        guard let type = json.string("type") else { return }
        switch type {
        case "session.ready":
            guard let ready = try? SessionReady(json: json) else { return }
            self.ready = ready
            playback.flush(toEpoch: ready.epoch)
            setState(.connected)
            emit(.ready(ready))
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: ready)
            }
        case "audio.interrupted":
            let epoch = UInt8(truncatingIfNeeded: json.int("epoch") ?? 0)
            playback.flush(toEpoch: epoch)
            send(["type": "playback.flushed", "epoch": Int(epoch)])
            emit(.interrupted(epoch: epoch, reason: json.string("reason") ?? ""))
        case "speakStart": emit(.agentSpeaking(true))
        case "speakEnd": emit(.agentSpeaking(false))
        case "speech":
            emit(.transcript(side: json.string("side") ?? "", text: json.string("utterance") ?? "", raw: json))
        case "system":
            emit(.system(json.string("content") ?? ""))
        case "pong", "stats":
            break
        case "session_ended", "SESSION_ENDED":
            ended = true
            finish(reason: json.string("reason") ?? "agent_ended")
        case "error", "fatal_error":
            let fatal = json.bool("fatal") ?? (type == "fatal_error")
            emit(.error(code: json.string("code"), message: json.string("message") ?? "", fatal: fatal))
            if fatal { finish(reason: "error") }
        default:
            emit(.message(json))
        }
    }

    // MARK: - State

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        emit(.state(new))
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }

    private func finish(reason: String) {
        guard state != .ended else { return }
        ended = true
        pingTask?.cancel()
        receiveTask?.cancel()
        audio.stop()
        if let socket, socket.closeCode == .invalid {
            socket.cancel(with: .normalClosure, reason: nil)
        }
        socket = nil
        setState(.ended)
        emit(.ended(reason: reason))
        continuation?.finish()
    }
}
