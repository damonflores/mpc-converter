import AppKit
import Foundation
import SwiftUI

@MainActor
final class ConverterModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, analyzing, converting, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scan: LibraryScan?
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var outcome: RunOutcome?
    @Published private(set) var canUndo = false
    @Published var dryRun: DryRunReport?
    @Published var alert: AlertMessage?
    @Published var confirmUndo = false

    private var engine: ConversionEngine?

    init() { canUndo = ManifestStore.load() != nil }

    var canConvert: Bool { phase == .ready }
    var acceptsDrops: Bool { phase == .idle || phase == .ready || phase == .finished }

    var undoSummary: String {
        guard let m = ManifestStore.load() else { return "" }
        let date = m.date.formatted(date: .abbreviated, time: .shortened)
        return "\(m.files.count) WAV files created on \(date) will be moved to the Trash."
    }

    // MARK: Input

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose a sample folder (or audio files) to convert"
        if panel.runModal() == .OK { load(panel.urls) }
    }

    func load(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, acceptsDrops else { return }
        outcome = nil
        phase = .scanning
        Task {
            let result = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(files) }.value
            if result.files.isEmpty {
                self.scan = nil
                self.phase = .idle
                self.alert = AlertMessage(title: "No audio files found",
                                          message: "MPC Converter reads WAV, AIFF, MP3, M4A/AAC, FLAC and CAF files.")
            } else {
                self.scan = result
                self.phase = .ready
            }
        }
    }

    func clear() {
        scan = nil
        outcome = nil
        phase = .idle
    }

    func backToReady() {
        outcome = nil
        phase = scan == nil ? .idle : .ready
    }

    // MARK: Output location

    private func resolveOutputBase(_ settings: AppSettings, scan: LibraryScan, interactive: Bool) -> URL? {
        switch settings.saveMode {
        case .askEachTime:
            guard interactive else { return nil }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose where to save the converted WAV folders"
            return panel.runModal() == .OK ? panel.url : nil
        case .nextToSource:
            let parent = scan.groups[0].isFolder ? scan.groups[0].root.deletingLastPathComponent() : scan.groups[0].root
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                alert = AlertMessage(title: "Can't write next to the source",
                                     message: "\(parent.path) is read-only. Pick another Save Mode in Settings.")
                return nil
            }
            return parent
        case .fixedFolder:
            var isDir: ObjCBool = false
            let path = settings.fixedFolderPath
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                alert = AlertMessage(title: "No save folder set",
                                     message: "Choose a save folder in Settings → Save Directory.")
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    // MARK: Convert

    func convertAll(_ settings: AppSettings) {
        guard let scan, phase == .ready else { return }
        let options = settings.options
        guard let base = resolveOutputBase(settings, scan: scan, interactive: true) else { return }

        phase = .analyzing
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                Planner.makePlan(scan: scan, outputBase: base, options: options, checkDisk: true)
            }.value
            guard !plan.jobs.isEmpty else {
                self.phase = .ready
                self.alert = AlertMessage(title: "Nothing to convert", message: "No audio files left after filtering.")
                return
            }

            self.total = plan.jobs.count
            self.done = 0
            self.currentName = ""
            self.phase = .converting

            let engine = ConversionEngine()
            self.engine = engine
            let outcome = await engine.run(plan: plan, options: options) { result in
                Task { @MainActor in
                    self.done += 1
                    self.currentName = result.name
                }
            }
            self.engine = nil

            let files = outcome.filesWritten.map { $0.standardizedFileURL.path }
            let dirs = outcome.createdDirectories.map { $0.standardizedFileURL.path }
            if !files.isEmpty || !dirs.isEmpty {
                ManifestStore.save(RunManifest(date: Date(), files: files, directories: dirs))
                self.canUndo = true
            }
            if let err = outcome.setupError {
                self.alert = AlertMessage(title: "Conversion couldn't start", message: err)
                self.phase = .ready
                return
            }
            self.outcome = outcome
            self.phase = .finished
        }
    }

    func cancel() { engine?.cancel() }

    // MARK: Dry run

    func runDryRun(_ settings: AppSettings) {
        guard let scan, phase == .ready else { return }
        let options = settings.options
        let base: URL
        let checkDisk: Bool
        let label: String
        if settings.saveMode == .askEachTime {
            base = URL(fileURLWithPath: "/MPC Converter Preview", isDirectory: true)
            checkDisk = false
            label = "Output folder (asked when you convert)"
        } else {
            guard let b = resolveOutputBase(settings, scan: scan, interactive: false) else { return }
            base = b
            checkDisk = true
            label = b.path
        }

        phase = .analyzing
        Task {
            let report = await Task.detached(priority: .userInitiated) { () -> DryRunReport in
                let plan = Planner.makePlan(scan: scan, outputBase: base, options: options, checkDisk: checkDisk)
                return DryRunBuilder.build(plan: plan, scan: scan, options: options, destinationLabel: label)
            }.value
            self.phase = .ready
            self.dryRun = report
        }
    }

    // MARK: Undo

    func undo() {
        let r = ManifestStore.undo()
        canUndo = false
        var msg = "\(r.trashedFiles) file\(r.trashedFiles == 1 ? "" : "s") moved to the Trash."
        if r.missing > 0 { msg += " \(r.missing) were already gone." }
        alert = AlertMessage(title: "Last conversion undone", message: msg)
        if phase == .finished { backToReady() }
    }

    func revealOutput() {
        guard let outcome else { return }
        let existing = outcome.topFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SourceFormatInfo?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: SourceFormatInfo?) { lock.lock(); storage[i] = v; lock.unlock() }
    var items: [SourceFormatInfo?] { lock.lock(); defer { lock.unlock() }; return storage }
}

enum DryRunBuilder {
    static func build(plan: Plan, scan: LibraryScan, options: ConversionOptions, destinationLabel: String) -> DryRunReport {
        let n = plan.jobs.count
        let box = ProbeBox(count: n)
        let jobs = plan.jobs
        DispatchQueue.concurrentPerform(iterations: n) { i in
            box.set(i, AudioTranscoder.probe(jobs[i].source))
        }
        let infos = box.items

        var rows: [DryRunRow] = []
        var renamed = 0, resample = 0, lossy = 0, unreadable = 0
        for (i, job) in plan.jobs.enumerated() {
            var notes: [String] = []
            let fmt: String
            if let info = infos[i] {
                fmt = info.label
                if info.sampleRate != ConversionOptions.targetSampleRate {
                    resample += 1
                    notes.append("resample → 44.1")
                }
                if info.isLossy { lossy += 1; notes.append("lossy source") }
                if options.strict && info.channels > 2 { notes.append("\(info.channels)ch → stereo") }
            } else {
                fmt = "—"
                unreadable += 1
                notes.append("can't read — will fail")
            }
            if job.renamed { renamed += 1; notes.append("renamed") }
            rows.append(DryRunRow(id: job.id, source: job.displaySource, sourceFormat: fmt,
                                  output: job.displayOutput, notes: notes.joined(separator: ", ")))
        }

        return DryRunReport(rows: rows, destinationLabel: destinationLabel,
                            outputFolderNames: plan.topFolders.map(\.lastPathComponent),
                            wavsOut: plan.jobs.reduce(0) { $0 + $1.targets.count },
                            renamed: renamed, needsResample: resample, lossy: lossy,
                            unreadable: unreadable, unsupportedSkipped: scan.unsupportedCount)
    }
}
