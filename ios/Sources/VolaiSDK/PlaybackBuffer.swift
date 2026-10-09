import Foundation

/// Thread-safe queue of downlink PCM with the playback epoch rule:
/// frames from an epoch other than the current one are dropped, and a
/// flush empties everything buffered so a barge-in cuts playback at once.
///
/// `pull` resamples from the source rate (24 kHz) to the output rate of the
/// audio engine with linear interpolation and pads with silence when the
/// queue is empty. It is called from the real-time render thread, so it
/// does no allocation beyond the output buffer it is handed.
final class PlaybackBuffer {
    private let lock = NSLock()
    private var queue: [[Int16]] = []
    private var queuedSamples = 0
    private var position: Double = 0
    private var primed = false
    private(set) var epoch: UInt8 = 0
    let sourceRate: Double
    let prebufferSamples: Int

    init(sourceRate: Int, prebufferMs: Int = 60) {
        self.sourceRate = Double(sourceRate)
        self.prebufferSamples = sourceRate / 1000 * prebufferMs
    }

    var bufferedMs: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(Double(queuedSamples) / sourceRate * 1000)
    }

    func push(epoch: UInt8, pcm: [Int16]) {
        guard !pcm.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return }
        queue.append(pcm)
        queuedSamples += pcm.count
    }

    func flush(toEpoch epoch: UInt8) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch
        queue.removeAll(keepingCapacity: true)
        queuedSamples = 0
        position = 0
        primed = false
    }

    /// Fills `out` (mono Float32 at `outputRate`) and returns how many samples carried audio.
    @discardableResult
    func pull(into out: UnsafeMutableBufferPointer<Float>, outputRate: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        let step = sourceRate / outputRate
        var produced = 0
        if !primed {
            if queuedSamples < prebufferSamples {
                for i in 0..<out.count { out[i] = 0 }
                return 0
            }
            primed = true
        }
        for i in 0..<out.count {
            guard let head = queue.first else {
                for j in i..<out.count { out[j] = 0 }
                primed = false
                return produced
            }
            let i0 = Int(position)
            let a = Float(head[i0]) / 32768
            let next: Int16
            if i0 + 1 < head.count {
                next = head[i0 + 1]
            } else if queue.count > 1 {
                next = queue[1][0]
            } else {
                next = head[i0]
            }
            let b = Float(next) / 32768
            let frac = Float(position - Double(i0))
            out[i] = a + (b - a) * frac
            produced += 1
            position += step
            if position >= Double(head.count) {
                position -= Double(head.count)
                queuedSamples -= head.count
                queue.removeFirst()
            }
        }
        return produced
    }
}
