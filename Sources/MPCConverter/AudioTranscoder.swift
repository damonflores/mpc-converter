import AudioToolbox
import Foundation

struct SourceFormatInfo: Sendable {
    let container: String
    let sampleRate: Double
    let channels: Int
    let sourceBits: Int?     // nil = lossy or float source
    let isFloat: Bool

    var isLossy: Bool { sourceBits == nil && !isFloat }

    var label: String {
        var kind = container
        if let b = sourceBits { kind += " \(b)-bit" } else if isFloat { kind += " float" }
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(sampleRate / 1000)) kHz"
            : String(format: "%.1f kHz", sampleRate / 1000)
        let ch = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels)ch"
        return [kind, rate, ch].joined(separator: " · ")
    }
}

enum TranscodeError: LocalizedError {
    case open(OSStatus)
    case format(OSStatus)
    case read(OSStatus)
    case noAudio
    case cancelled

    var errorDescription: String? {
        switch self {
        case .open(let s): return "Couldn't open file — unsupported or damaged (\(AudioTranscoder.describe(s)))"
        case .format(let s): return "Couldn't set up decoder (\(AudioTranscoder.describe(s)))"
        case .read(let s): return "Decoding failed partway through (\(AudioTranscoder.describe(s)))"
        case .noAudio: return "File contains no audio channels"
        case .cancelled: return "Cancelled"
        }
    }
}

enum AudioTranscoder {
    private static let chunkFrames: UInt32 = 16_384

    // MARK: Probe (dry run)

    static func probe(_ url: URL) -> SourceFormatInfo? {
        var extRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &extRef) == noErr, let ext = extRef else { return nil }
        defer { ExtAudioFileDispose(ext) }
        guard let asbd = fileFormat(ext) else { return nil }
        return info(asbd, url: url)
    }

    // MARK: Convert

    static func transcode(source: URL, targets: [OutputTarget], options: ConversionOptions,
                          isCancelled: () -> Bool) throws {
        var extRef: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(source as CFURL, &extRef)
        guard openStatus == noErr, let ext = extRef else { throw TranscodeError.open(openStatus) }
        defer { ExtAudioFileDispose(ext) }

        guard let fileASBD = fileFormat(ext) else { throw TranscodeError.format(-1) }
        let src = info(fileASBD, url: source)
        let inCh = src.channels
        guard inCh > 0 else { throw TranscodeError.noAudio }

        // Ask Core Audio to hand us interleaved Float32 at 44.1 kHz (it resamples for us).
        var client = AudioStreamBasicDescription(
            mSampleRate: ConversionOptions.targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(4 * inCh),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * inCh),
            mChannelsPerFrame: UInt32(inCh),
            mBitsPerChannel: 32,
            mReserved: 0)
        let st = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { throw TranscodeError.format(st) }

        let resampling = src.sampleRate != ConversionOptions.targetSampleRate
        if resampling { configureHighQualitySRC(ext) }

        let metadata: [String: String]? = options.stripMetadata ? nil : readInfoChunk(ext)

        let outCh = (options.strict && inCh > 2) ? 2 : inCh
        let downmix = outCh != inCh
        // Dither only when 16-bit output actually loses information.
        let needsDither = options.dither16
            && (resampling || downmix || src.sourceBits == nil || (src.sourceBits ?? 0) > 16)

        var writers: [WAVWriter] = []
        var success = false
        defer { if !success { writers.forEach { $0.abort() } } }

        let seed = UInt64(bitPattern: Int64(source.path.hashValue)) | 1
        for t in targets {
            writers.append(try WAVWriter(url: t.url, bitDepth: t.bitDepth, channels: outCh,
                                         dither: t.bitDepth == 16 && needsDither, seed: seed))
        }

        var buffer = [Float](repeating: 0, count: Int(chunkFrames) * inCh)
        var mixBuffer = downmix ? [Float](repeating: 0, count: Int(chunkFrames) * 2) : []

        while true {
            if isCancelled() { throw TranscodeError.cancelled }
            var frames = chunkFrames
            let readStatus: OSStatus = buffer.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(inCh),
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                return ExtAudioFileRead(ext, &frames, &abl)
            }
            guard readStatus == noErr else { throw TranscodeError.read(readStatus) }
            if frames == 0 { break }
            let n = Int(frames)

            if downmix {
                // >2 channels → stereo: even channels to L, odd channels to R (averaged).
                let evens = Float((inCh + 1) / 2), odds = Float(inCh / 2)
                for f in 0..<n {
                    var l: Float = 0, r: Float = 0
                    for c in 0..<inCh {
                        let s = buffer[f * inCh + c]
                        if c % 2 == 0 { l += s } else { r += s }
                    }
                    mixBuffer[f * 2] = l / evens
                    mixBuffer[f * 2 + 1] = r / odds
                }
                try mixBuffer.withUnsafeBufferPointer { p in
                    let slice = UnsafeBufferPointer(rebasing: p[0..<(n * 2)])
                    for w in writers { try w.append(slice) }
                }
            } else {
                try buffer.withUnsafeBufferPointer { p in
                    let slice = UnsafeBufferPointer(rebasing: p[0..<(n * inCh)])
                    for w in writers { try w.append(slice) }
                }
            }
        }

        for w in writers { try w.finish(info: metadata) }
        success = true
    }

    // MARK: Helpers

    private static func fileFormat(_ ext: ExtAudioFileRef) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    private static func info(_ a: AudioStreamBasicDescription, url: URL) -> SourceFormatInfo {
        let isFloat = a.mFormatID == kAudioFormatLinearPCM && (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var bits: Int?
        switch a.mFormatID {
        case kAudioFormatLinearPCM:
            bits = isFloat ? nil : Int(a.mBitsPerChannel)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // Both use 1=16, 2=20, 3=24, 4=32-bit source flags.
            switch a.mFormatFlags { case 1: bits = 16; case 2: bits = 20; case 3: bits = 24; case 4: bits = 32; default: bits = nil }
        default:
            bits = nil
        }
        var container = url.pathExtension.uppercased()
        if a.mFormatID == kAudioFormatAppleLossless { container = "ALAC" }
        return SourceFormatInfo(container: container, sampleRate: a.mSampleRate,
                                channels: Int(a.mChannelsPerFrame), sourceBits: bits, isFloat: isFloat)
    }

    private static func configureHighQualitySRC(_ ext: ExtAudioFileRef) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
              let conv = converter else { return }
        var complexity = UInt32(kAudioConverterSampleRateConverterComplexity_Mastering)
        _ = AudioConverterSetProperty(conv, kAudioConverterSampleRateConverterComplexity,
                                      UInt32(MemoryLayout<UInt32>.size), &complexity)
        var quality = UInt32(kAudioConverterQuality_Max)
        _ = AudioConverterSetProperty(conv, kAudioConverterSampleRateConverterQuality,
                                      UInt32(MemoryLayout<UInt32>.size), &quality)
        // Tell ExtAudioFile the converter changed.
        var config: CFArray? = nil
        _ = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ConverterConfig,
                                    UInt32(MemoryLayout<CFArray?>.size), &config)
    }

    /// Basic tags → RIFF INFO ids (used only when "Strip Metadata" is off).
    private static func readInfoChunk(_ ext: ExtAudioFileRef) -> [String: String]? {
        var fileID: AudioFileID?
        var size = UInt32(MemoryLayout<AudioFileID?>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioFile, &size, &fileID) == noErr,
              let afid = fileID else { return nil }
        var dictRef: Unmanaged<CFDictionary>?
        var dsize = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(afid, kAudioFilePropertyInfoDictionary, &dsize, &dictRef) == noErr,
              let dict = dictRef?.takeRetainedValue() as? [String: Any] else { return nil }
        let map = ["title": "INAM", "artist": "IART", "album": "IPRD", "comments": "ICMT",
                   "genre": "IGNR", "year": "ICRD", "copyright": "ICOP"]
        var out: [String: String] = [:]
        for (k, id) in map {
            if let v = dict[k] as? String, !v.isEmpty { out[id] = v }
        }
        return out.isEmpty ? nil : out
    }

    static func describe(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let bytes = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let str = String(bytes: bytes, encoding: .ascii) {
            return "'\(str)'"
        }
        return "error \(s)"
    }
}
