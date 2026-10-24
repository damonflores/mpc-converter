import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var bitDepthMode: BitDepthMode { didSet { d.set(bitDepthMode.rawValue, forKey: "bitDepthMode") } }
    @Published var strictMode: Bool { didSet { d.set(strictMode, forKey: "strictMode") } }
    @Published var stripMetadata: Bool { didSet { d.set(stripMetadata, forKey: "stripMetadata") } }
    @Published var sanitizeFilenames: Bool { didSet { d.set(sanitizeFilenames, forKey: "sanitizeFilenames") } }
    @Published var sanitizeFolders: Bool { didSet { d.set(sanitizeFolders, forKey: "sanitizeFolders") } }
    @Published var maxNameLength: MaxNameLength { didSet { d.set(maxNameLength.rawValue, forKey: "maxNameLength") } }
    @Published var saveMode: SaveMode { didSet { d.set(saveMode.rawValue, forKey: "saveMode") } }
    @Published var fixedFolderPath: String { didSet { d.set(fixedFolderPath, forKey: "fixedFolderPath") } }
    @Published var workerThreads: Int { didSet { d.set(workerThreads, forKey: "workerThreads") } }
    @Published var dither16: Bool { didSet { d.set(dither16, forKey: "dither16") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        bitDepthMode = BitDepthMode(rawValue: d.string(forKey: "bitDepthMode") ?? "") ?? .both
        strictMode = bool("strictMode", true)
        stripMetadata = bool("stripMetadata", true)
        sanitizeFilenames = bool("sanitizeFilenames", true)
        sanitizeFolders = bool("sanitizeFolders", false)
        maxNameLength = MaxNameLength(rawValue: d.integer(forKey: "maxNameLength")) ?? .noLimit
        saveMode = SaveMode(rawValue: d.string(forKey: "saveMode") ?? "") ?? .askEachTime
        fixedFolderPath = d.string(forKey: "fixedFolderPath") ?? ""
        let defThreads = min(8, ProcessInfo.processInfo.activeProcessorCount)
        let stored = d.integer(forKey: "workerThreads")
        workerThreads = stored > 0 ? stored : defThreads
        dither16 = bool("dither16", true)
    }

    /// Strict mode always strips metadata and cleans file names.
    var effectiveStripMetadata: Bool { strictMode || stripMetadata }
    var effectiveSanitizeFilenames: Bool { strictMode || sanitizeFilenames }

    var options: ConversionOptions {
        ConversionOptions(bitDepths: bitDepthMode.depths,
                          strict: strictMode,
                          stripMetadata: effectiveStripMetadata,
                          sanitizeFilenames: effectiveSanitizeFilenames,
                          sanitizeFolders: sanitizeFolders,
                          maxNameLength: maxNameLength.rawValue,
                          workerThreads: workerThreads,
                          dither16: dither16)
    }

    var summary: String {
        let depths = bitDepthMode == .both ? "16 + 24-bit" : bitDepthMode.label
        return "→ WAV · 44.1 kHz · \(depths)" + (strictMode ? " · Strict" : "")
    }
}
