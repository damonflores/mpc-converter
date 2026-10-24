import Foundation

// MARK: - Settings enums

enum BitDepthMode: String, CaseIterable, Identifiable, Sendable {
    case both, sixteen, twentyFour
    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Both"
        case .sixteen: return "16-bit"
        case .twentyFour: return "24-bit"
        }
    }

    var depths: [Int] {
        switch self {
        case .both: return [16, 24]
        case .sixteen: return [16]
        case .twentyFour: return [24]
        }
    }
}

enum SaveMode: String, CaseIterable, Identifiable, Sendable {
    case askEachTime, nextToSource, fixedFolder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .askEachTime: return "Ask Each Time"
        case .nextToSource: return "Next to Source"
        case .fixedFolder: return "Fixed Folder"
        }
    }

    var footer: String {
        switch self {
        case .askEachTime: return "You'll be prompted to choose an output folder each time."
        case .nextToSource: return "Converted folders are created next to the folder you dropped in."
        case .fixedFolder: return "Converted folders are always saved to the folder below."
        }
    }
}

enum MaxNameLength: Int, CaseIterable, Identifiable, Sendable {
    case noLimit = 0, chars16 = 16, chars24 = 24, chars32 = 32, chars64 = 64
    var id: Int { rawValue }
    var label: String { self == .noLimit ? "No Limit" : "\(rawValue) characters" }
}

/// Immutable snapshot of the settings, handed to the background workers.
struct ConversionOptions: Sendable {
    var bitDepths: [Int]
    var strict: Bool
    var stripMetadata: Bool
    var sanitizeFilenames: Bool
    var sanitizeFolders: Bool
    var maxNameLength: Int          // 0 = no limit, counted without ".wav"
    var workerThreads: Int
    var dither16: Bool

    static let targetSampleRate: Double = 44_100
}

// MARK: - Scan

struct ScanGroup: Sendable {
    let name: String
    let root: URL
    let isFolder: Bool
}

struct ScannedFile: Sendable {
    let url: URL
    let groupIndex: Int
    let relativeDirs: [String]
    let size: Int64
}

struct LibraryScan: Sendable {
    let groups: [ScanGroup]
    let files: [ScannedFile]
    let unsupportedCount: Int
    let totalBytes: Int64
    let countsByExtension: [String: Int]

    var displayName: String {
        if groups.count == 1 { return groups[0].isFolder ? groups[0].name : "\(files.count) files" }
        return "\(groups.count) items"
    }

    var isSingleFolder: Bool { groups.count == 1 && groups[0].isFolder }

    var formatSummary: [FormatCount] {
        countsByExtension
            .map { FormatCount(name: $0.key.uppercased(), count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}

struct FormatCount: Identifiable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

// MARK: - Plan

struct OutputTarget: Sendable, Hashable {
    let bitDepth: Int
    let url: URL
}

struct ConversionJob: Identifiable, Sendable {
    let id: Int
    let source: URL
    let displaySource: String
    let displayOutput: String
    let targets: [OutputTarget]
    let renamed: Bool
}

struct Plan: Sendable {
    let jobs: [ConversionJob]
    let directories: [URL]
    let topFolders: [URL]
}

// MARK: - Results

enum JobStatus: Sendable {
    case converted
    case failed(String)
    case cancelled
}

struct JobResult: Sendable {
    let jobID: Int
    let name: String
    let displaySource: String
    let status: JobStatus
    let outputs: [URL]
}

struct RunOutcome: Sendable {
    let results: [JobResult]
    let createdDirectories: [URL]
    let topFolders: [URL]
    let bitDepths: [Int]
    let wasCancelled: Bool
    let setupError: String?

    var convertedCount: Int { results.filter { if case .converted = $0.status { return true }; return false }.count }
    var failures: [(String, String)] {
        results.compactMap { if case .failed(let msg) = $0.status { return ($0.displaySource, msg) }; return nil }
    }
    var filesWritten: [URL] { results.flatMap { $0.outputs } }
}

// MARK: - Dry run

struct DryRunRow: Identifiable, Sendable {
    let id: Int
    let source: String
    let sourceFormat: String
    let output: String
    let notes: String
}

struct DryRunReport: Identifiable, Sendable {
    let id = UUID()
    let rows: [DryRunRow]
    let destinationLabel: String
    let outputFolderNames: [String]
    let wavsOut: Int
    let renamed: Int
    let needsResample: Int
    let lossy: Int
    let unreadable: Int
    let unsupportedSkipped: Int
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
