import Foundation
import AVFoundation

/// Microphone capture and PCM playback on AVAudioEngine.
///
/// Capture: a tap on the input node, resampled to 16 kHz Int16 mono in
/// 20 ms frames and handed to `onFrame`. Playback: an AVAudioSourceNode
/// pulling from the PlaybackBuffer at the engine's output rate.
///
/// On iOS the audio session is configured for play-and-record in voice-chat
/// mode, which is what gives the SDK hardware echo cancellation; the server
/// relies on it for full-duplex barge-in (docs/voice-ws-protocol.md).
final class VoiceAudioEngine {
    private let engine = AVAudioEngine()
    private let resampler = UplinkResampler()
    private var sourceNode: AVAudioSourceNode?
    private let playback: PlaybackBuffer
    private var onFrame: (([Int16]) -> Void)?
    private(set) var isRunning = false
    var muted = false
    var playbackMuted = false

    init(playback: PlaybackBuffer) {
        self.playback = playback
    }

    func start(onFrame: @escaping ([Int16]) -> Void) throws {
        guard !isRunning else { return }
        self.onFrame = onFrame
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.muted, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            let samples = UnsafeBufferPointer(start: channel, count: frames)
            self.resampler.process(samples, inputRate: inputFormat.sampleRate) { frame in
                self.onFrame?(frame)
            }
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let outputRate = outputFormat.sampleRate
        let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
        let node = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let self, let data = abl[0].mData else { return noErr }
            let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            if self.playbackMuted {
                for i in 0..<out.count { out[i] = 0 }
                return noErr
            }
            self.playback.pull(into: out, outputRate: outputRate)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}
