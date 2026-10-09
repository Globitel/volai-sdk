import Foundation

/// Binary frame codec for the ws_audio voice transport (docs/voice-ws-protocol.md).
///
/// Both directions share a 4-byte header: version (1), playback epoch
/// (downlink) or 0 (uplink), a big-endian uint16 sequence number, then
/// PCM16 little-endian mono samples.
public enum AudioFrame {
    public static let version: UInt8 = 1
    public static let headerBytes = 4
    public static let uplinkRate = 16_000
    public static let downlinkRate = 24_000
    public static let frameMs = 20
    /// 320 samples: 20 ms at 16 kHz.
    public static let uplinkSamples = uplinkRate / 1000 * frameMs
    /// 480 samples: 20 ms at 24 kHz.
    public static let downlinkSamples = downlinkRate / 1000 * frameMs

    public struct Decoded: Equatable {
        public let epoch: UInt8
        public let seq: UInt16
        public let pcm: [Int16]
    }

    public static func encode(epoch: UInt8, seq: UInt16, pcm: [Int16]) -> Data {
        var data = Data(capacity: headerBytes + pcm.count * 2)
        data.append(version)
        data.append(epoch)
        data.append(UInt8(seq >> 8))
        data.append(UInt8(seq & 0xff))
        for sample in pcm {
            let u = UInt16(bitPattern: sample)
            data.append(UInt8(u & 0xff))
            data.append(UInt8(u >> 8))
        }
        return data
    }

    /// Returns nil for anything malformed (wrong version, short header, odd payload).
    public static func decode(_ data: Data) -> Decoded? {
        guard data.count >= headerBytes, data[data.startIndex] == version else { return nil }
        let payload = data.count - headerBytes
        guard payload % 2 == 0 else { return nil }
        let base = data.startIndex
        let epoch = data[base + 1]
        let seq = UInt16(data[base + 2]) << 8 | UInt16(data[base + 3])
        var pcm = [Int16](repeating: 0, count: payload / 2)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<pcm.count {
                let lo = UInt16(bytes[headerBytes + i * 2])
                let hi = UInt16(bytes[headerBytes + i * 2 + 1])
                pcm[i] = Int16(bitPattern: hi << 8 | lo)
            }
        }
        return Decoded(epoch: epoch, seq: seq, pcm: pcm)
    }
}
