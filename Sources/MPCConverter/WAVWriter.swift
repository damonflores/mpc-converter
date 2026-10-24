import Foundation

enum WAVWriterError: LocalizedError {
    case create(String)
    case tooLarge
    case exists(String)

    var errorDescription: String? {
        switch self {
        case .create(let p): return "Couldn't create output file at \(p)"
        case .tooLarge: return "Output would exceed the 4 GB WAV limit"
        case .exists(let n): return "\(n) already exists"
        }
    }
}

/// Streams interleaved Float32 audio into a canonical 44-byte-header PCM WAV
/// (format tag 1, no extensible header, no bext/JUNK/cue/smpl chunks).
/// Writes to a hidden ".partial" file and renames on success.
final class WAVWriter {
    static let sampleRate: UInt32 = 44_100

    let finalURL: URL
    let bitDepth: Int
    let channels: Int
    private let tempURL: URL
    private let handle: FileHandle
    private let dither: Bool
    private var rng: UInt64
    private var dataBytes: UInt64 = 0
    private var finished = false
    private var closed = false

    init(url: URL, bitDepth: Int, channels: Int, dither: Bool, seed: UInt64) throws {
        precondition(bitDepth == 16 || bitDepth == 24)
        finalURL = url
        self.bitDepth = bitDepth
        self.channels = channels
        self.dither = dither
        rng = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")

        if FileManager.default.fileExists(atPath: url.path) { throw WAVWriterError.exists(url.lastPathComponent) }
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WAVWriterError.create(tempURL.path)
        }
        handle = try FileHandle(forWritingTo: tempURL)
        try handle.write(contentsOf: Self.header(channels: channels, bitDepth: bitDepth, dataSize: 0, riffSize: 36))
    }

    /// Interleaved samples in the range -1...1 (values outside are clipped).
    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        let bps = bitDepth / 8
        var bytes = [UInt8](repeating: 0, count: samples.count * bps)
        if bitDepth == 16 {
            for i in 0..<samples.count {
                var x = Double(samples[i]) * 32768.0
                if !x.isFinite { x = 0 }
                if dither { x += tpdf() }
                x = min(max(x.rounded(), -32768), 32767)
                let v = Int32(x)
                bytes[i &* 2] = UInt8(truncatingIfNeeded: v)
                bytes[i &* 2 &+ 1] = UInt8(truncatingIfNeeded: v >> 8)
            }
        } else {
            for i in 0..<samples.count {
                var x = Double(samples[i]) * 8_388_608.0
                if !x.isFinite { x = 0 }
                x = min(max(x.rounded(), -8_388_608), 8_388_607)
                let v = Int32(x)
                let o = i &* 3
                bytes[o] = UInt8(truncatingIfNeeded: v)
                bytes[o &+ 1] = UInt8(truncatingIfNeeded: v >> 8)
                bytes[o &+ 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
        }
        try handle.write(contentsOf: Data(bytes))
        dataBytes += UInt64(bytes.count)
    }

    /// Finalise header sizes, optionally append a LIST/INFO chunk, then move into place.
    func finish(info: [String: String]?) throws {
        let pad: UInt64 = dataBytes % 2
        if pad == 1 { try handle.write(contentsOf: Data([0])) }

        var list = Data()
        if let info, !info.isEmpty {
            var body = Data("INFO".utf8)
            for key in info.keys.sorted() {
                guard let value = info[key], key.utf8.count == 4 else { continue }
                var text = Data(value.utf8)
                text.append(0)
                body.append(contentsOf: Array(key.utf8))
                body.appendLE(UInt32(text.count))
                body.append(text)
                if text.count % 2 == 1 { body.append(0) }
            }
            if body.count > 4 {
                list.append(contentsOf: Array("LIST".utf8))
                list.appendLE(UInt32(body.count))
                list.append(body)
            }
        }
        if !list.isEmpty { try handle.write(contentsOf: list) }

        let riff = 36 + dataBytes + pad + UInt64(list.count)
        guard riff <= UInt64(UInt32.max) else { throw WAVWriterError.tooLarge }

        try handle.seek(toOffset: 4)
        var d = Data(); d.appendLE(UInt32(riff))
        try handle.write(contentsOf: d)
        try handle.seek(toOffset: 40)
        d = Data(); d.appendLE(UInt32(dataBytes))
        try handle.write(contentsOf: d)
        try handle.synchronize()
        try handle.close()
        closed = true

        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        finished = true
    }

    /// Remove anything this writer produced (partial or finished file).
    func abort() {
        if !closed { try? handle.close(); closed = true }
        try? FileManager.default.removeItem(at: tempURL)
        if finished { try? FileManager.default.removeItem(at: finalURL) }
    }

    // MARK: helpers

    private func nextUniform() -> Double {
        // xorshift64*
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        let r = rng &* 2_685_821_657_736_338_717
        return Double(r >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Triangular dither, ±1 LSB peak.
    private func tpdf() -> Double { nextUniform() - nextUniform() }

    static func header(channels: Int, bitDepth: Int, dataSize: UInt32, riffSize: UInt32) -> Data {
        let blockAlign = UInt16(channels * bitDepth / 8)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.appendLE(riffSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.appendLE(UInt32(16))
        d.appendLE(UInt16(1))                                  // PCM
        d.appendLE(UInt16(channels))
        d.appendLE(sampleRate)
        d.appendLE(sampleRate * UInt32(blockAlign))            // byte rate
        d.appendLE(blockAlign)
        d.appendLE(UInt16(bitDepth))
        d.append(contentsOf: Array("data".utf8)); d.appendLE(dataSize)
        return d
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    mutating func appendLE(_ v: UInt16) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }
}
