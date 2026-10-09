import XCTest
@testable import VolaiSDK

final class FrameTests: XCTestCase {
    func testRoundTripWithWrappingHeaderFields() {
        let pcm: [Int16] = [1, -2, 32767, -32768, 0]
        let data = AudioFrame.encode(epoch: UInt8(truncatingIfNeeded: 300), seq: UInt16(truncatingIfNeeded: 70000), pcm: pcm)
        XCTAssertEqual(data.count, 4 + pcm.count * 2)
        let decoded = AudioFrame.decode(data)
        XCTAssertEqual(decoded?.epoch, UInt8(truncatingIfNeeded: 300))
        XCTAssertEqual(decoded?.seq, UInt16(truncatingIfNeeded: 70000))
        XCTAssertEqual(decoded?.pcm, pcm)
        // little-endian payload, big-endian sequence
        XCTAssertEqual([UInt8](data.prefix(6)), [1, 44, 0x11, 0x70, 0x01, 0x00])
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(AudioFrame.decode(Data([2, 0, 0, 0, 1, 1])), "wrong version")
        XCTAssertNil(AudioFrame.decode(Data([1, 0, 0])), "short header")
        XCTAssertNil(AudioFrame.decode(Data([1, 0, 0, 0, 1])), "odd payload")
        XCTAssertEqual(AudioFrame.decode(Data([1, 3, 0, 9]))?.pcm, [], "header only is an empty frame")
    }

    func testFrameSizes() {
        XCTAssertEqual(AudioFrame.uplinkSamples, 320)
        XCTAssertEqual(AudioFrame.downlinkSamples, 480)
    }
}

final class PlaybackBufferTests: XCTestCase {
    private func pull(_ buffer: PlaybackBuffer, count: Int, rate: Double = 24_000) -> [Float] {
        var out = [Float](repeating: 99, count: count)
        out.withUnsafeMutableBufferPointer { buffer.pull(into: $0, outputRate: rate) }
        return out
    }

    func testPrebufferThenPlaysInOrder() {
        let buffer = PlaybackBuffer(sourceRate: 24_000, prebufferMs: 20)
        XCTAssertEqual(pull(buffer, count: 4), [0, 0, 0, 0], "silence before any audio")
        buffer.push(epoch: 0, pcm: [Int16](repeating: 16384, count: 240)) // 10 ms, below prebuffer
        XCTAssertEqual(pull(buffer, count: 2), [0, 0], "still priming")
        buffer.push(epoch: 0, pcm: [Int16](repeating: 16384, count: 240))
        let out = pull(buffer, count: 480)
        XCTAssertEqual(out.first!, 0.5, accuracy: 0.001)
        XCTAssertEqual(out.last!, 0.5, accuracy: 0.001)
        XCTAssertEqual(pull(buffer, count: 2), [0, 0], "drained back to silence")
    }

    func testEpochDropsStaleFramesAndFlushClearsTheQueue() {
        let buffer = PlaybackBuffer(sourceRate: 24_000, prebufferMs: 0)
        buffer.push(epoch: 0, pcm: [Int16](repeating: 1000, count: 480))
        XCTAssertEqual(buffer.bufferedMs, 20)
        buffer.flush(toEpoch: 1)
        XCTAssertEqual(buffer.bufferedMs, 0)
        buffer.push(epoch: 0, pcm: [Int16](repeating: 1000, count: 480))
        XCTAssertEqual(buffer.bufferedMs, 0, "frame from the old epoch is dropped")
        buffer.push(epoch: 1, pcm: [Int16](repeating: 1000, count: 480))
        XCTAssertEqual(buffer.bufferedMs, 20)
    }

    func testResamplesToTheOutputRate() {
        let buffer = PlaybackBuffer(sourceRate: 24_000, prebufferMs: 0)
        buffer.push(epoch: 0, pcm: [Int16](repeating: 8192, count: 480)) // 20 ms
        let out = pull(buffer, count: 960, rate: 48_000) // 20 ms at 48 kHz
        XCTAssertEqual(out[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(out[958], 0.25, accuracy: 0.001)
        XCTAssertEqual(buffer.bufferedMs, 0)
    }
}

final class ResamplerTests: XCTestCase {
    func testEmitsTwentyMillisecondFramesFrom48k() {
        let resampler = UplinkResampler()
        var frames: [[Int16]] = []
        let input = [Float](repeating: 0.5, count: 48_000 / 50) // 20 ms at 48 kHz
        input.withUnsafeBufferPointer { resampler.process($0, inputRate: 48_000) { frames.append($0) } }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 320)
        XCTAssertEqual(frames[0][100], 16383)
    }

    func testFrameBoundariesDoNotDriftAcrossCalls() {
        let resampler = UplinkResampler()
        var frames = 0
        let chunk = [Float](repeating: 0.1, count: 441) // odd sizes at 44.1 kHz
        for _ in 0..<100 {
            chunk.withUnsafeBufferPointer { resampler.process($0, inputRate: 44_100) { _ in frames += 1 } }
        }
        // 100 x 441 samples = 1 s at 44.1 kHz = 50 frames at 16 kHz (minus the one still filling)
        XCTAssertTrue((48...50).contains(frames), "got \(frames)")
    }
}

final class ModelTests: XCTestCase {
    func testSessionReadyParsesTheContractShape() throws {
        let json = JSONObject([
            "type": "session.ready", "session_id": "s1", "contract": 1,
            "uplink": ["rate": 16000, "frame_ms": 20], "downlink": ["rate": 24000, "frame_ms": 20],
            "epoch": 3, "resume_token": "abc", "grace_ms": 15000, "resumed": true,
        ])
        let ready = try SessionReady(json: json)
        XCTAssertEqual(ready.sessionId, "s1")
        XCTAssertEqual(ready.epoch, 3)
        XCTAssertEqual(ready.downlinkRate, 24000)
        XCTAssertTrue(ready.resumed)
    }

    func testResumeURLKeepsHostAndPath() {
        let url = URL(string: "wss://gicc.globitel.com/gicc/ws/sdk/voice?token=abc")!
        let resume = resumeURL(from: url, sessionId: "s1", resumeToken: "r1")!
        XCTAssertEqual(resume.absoluteString, "wss://gicc.globitel.com/gicc/ws/sdk/voice?resume_session=s1&resume_token=r1")
    }

    func testSessionRequestBodyOnlyCarriesGivenFields() {
        let body = SessionRequest(agentId: "a", deviceId: "d", sessionGrant: "g").body(type: "voice", transport: "ws_audio")
        XCTAssertEqual(body["agent_id"] as? String, "a")
        XCTAssertEqual(body["transport"] as? String, "ws_audio")
        XCTAssertEqual(body["session_grant"] as? String, "g")
        XCTAssertNil(body["caller_phone"])
    }

    func testVoiceSessionInfoRejectsMissingFields() {
        XCTAssertThrowsError(try VoiceSessionInfo(json: JSONObject(["session_id": "s"])))
    }
}
