import Foundation

/// Streaming linear resampler from Float32 mono at any rate to Int16 mono at
/// `targetRate`, emitting fixed-size frames (20 ms at 16 kHz for the uplink).
/// Keeps the fractional read position across calls so frame boundaries do
/// not drift.
final class UplinkResampler {
    let targetRate: Double
    let frameSamples: Int
    private var ratio: Double = 1
    private var pending: [Float] = []
    private var position: Double = 0
    private var frame: [Int16]
    private var frameFill = 0

    init(targetRate: Int = AudioFrame.uplinkRate, frameSamples: Int = AudioFrame.uplinkSamples) {
        self.targetRate = Double(targetRate)
        self.frameSamples = frameSamples
        self.frame = [Int16](repeating: 0, count: frameSamples)
    }

    /// Feeds input samples at `inputRate`; calls `emit` for every completed frame.
    func process(_ input: UnsafeBufferPointer<Float>, inputRate: Double, emit: ([Int16]) -> Void) {
        ratio = inputRate / targetRate
        pending.append(contentsOf: input)
        while Int(position) + 1 < pending.count {
            let i0 = Int(position)
            let frac = Float(position - Double(i0))
            let a = pending[i0], b = pending[i0 + 1]
            var v = a + (b - a) * frac
            v = max(-1, min(1, v))
            frame[frameFill] = Int16(v < 0 ? v * 32768 : v * 32767)
            frameFill += 1
            position += ratio
            if frameFill == frameSamples {
                emit(frame)
                frameFill = 0
            }
        }
        let consumed = Int(position)
        if consumed > 0 {
            pending.removeFirst(min(consumed, pending.count))
            position -= Double(consumed)
        }
    }
}
