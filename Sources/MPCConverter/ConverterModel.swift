import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ConverterModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, analyzing, converting, finished }

    let settings: AppSettings

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scan: LibraryScan?
    @Published private(set) var rows: [FileRow] = []
    @Published private(set) var displayOrder: [Int] = []
    @Published private(set) var probing = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var outcome: RunOutcome?
    @Published private(set) var canUndo = false
    @Published var tableSelection = Set<Int>()
    @Published var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\FileRow.path)] {
        didSet { if sortOrder != oldValue { updateDisplayOrder() } }
    }
    @Published var searchText = "" { didSet { if searchText != oldValue { updateDisplayOrder() } } }
    @Published var dryRunSummary: DryRunSummary?
    @Published var alert: AlertMessage?
    @Published var confirmUndo = false

    private var engine: ConversionEngine?
    private var probeTask: Task<Void, Never>?
    private var generation = 0
    private var refreshScheduled = false
    private var cancellables = Set<AnyCancellable>()
    private static let previewBase = URL(fileURLWithPath: "/MPC Converter Preview", isDirectory: true)

    init(settings: AppSettings) {
        self.settings = settings
        canUndo = ManifestStore.load() != nil
        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)
    }

    // MARK: Derived

    var displayedRows: [FileRow] { displayOrder.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    var includedCount: Int { rows.reduce(0) { $0 + ($1.included ? 1 : 0) } }
    var includedBytes: Int64 { rows.reduce(0) { $0 + ($1.included ? $1.size : 0) } }
    var canConvert: Bool { phase == .ready && includedCount > 0 }
    var acceptsDrops: Bool { phase == .idle || phase == .ready || phase == .finished }
    var isBusy: Bool { phase == .converting || phase == .analyzing || phase == .scanning }

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
        Diagnostics.log("load: \(files.map(\.path))")
        probeTask?.cancel()
        generation += 1
        let token = generation
        outcome = nil
        dryRunSummary = nil
        phase = .scanning
        Task {
            let result = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(files) }.value
            guard token == self.generation else { return }
            if result.files.isEmpty {
                self.reset()
                self.alert = AlertMessage(title: "No audio files found",
                                          message: "MPC Converter reads WAV, AIFF, MP3, M4A/AAC, FLAC and CAF files.")
                return
            }
            Diagnostics.log("scan done: \(result.files.count) audio, \(result.unsupportedCount) non-audio")
            self.scan = result
            let prefixGroup = result.groups.count > 1
            self.rows = result.files.enumerated().map { i, f in
                var parts = f.relativeDirs + [f.url.lastPathComponent]
                if prefixGroup && result.groups[f.groupIndex].isFolder {
                    parts.insert(result.groups[f.groupIndex].name, at: 0)
                }
                return FileRow(id: i, path: parts.joined(separator: "/"), size: f.size)
            }
            self.tableSelection = []
            self.phase = .ready
            self.refreshPreview()
            self.startProbing(token: token)
        }
    }

    private func reset() {
        probeTask?.cancel()
        scan = nil
        rows = []
        displayOrder = []
        tableSelection = []
        outcome = nil
        dryRunSummary = nil
        probing = false
        phase = .idle
    }

    func clear() {
        generation += 1
        reset()
    }

    func backToReady() {
        outcome = nil
        for i in rows.indices { rows[i].status = .none }
        phase = scan == nil ? .idle : .ready
    }

    // MARK: Probing source formats (background, in batches)

    private func startProbing(token: Int) {
        guard let scan else { return }
        let urls = scan.files.map(\.url)
        probing = true
        probeTask = Task {
            let batch = 64
            var start = 0
            while start < urls.count {
                let end = min(start + batch, urls.count)
                let slice = Array(urls[start..<end])
                let infos = await Task.detached(priority: .utility) { () -> [SourceFormatInfo?] in
                    let box = ProbeBox(count: slice.count)
                    DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                        box.set(i, AudioTranscoder.probe(slice[i]))
                    }
                    return box.items
                }.value
                if Task.isCancelled || token != self.generation { return }
                for (offset, info) in infos.enumerated() {
                    let i = start + offset
                    if let info {
                        self.rows[i].format = info.label
                        self.rows[i].sampleRate = info.sampleRate
                        self.rows[i].channels = info.channels
                        self.rows[i].isLossy = info.isLossy
                    } else {
                        self.rows[i].format = "unreadable"
                        self.rows[i].unreadable = true
                    }
                }
                start = end
                self.refreshPreview()
            }
            if token == self.generation { self.probing = false }
        }
    }

    // MARK: Selection

    func isIncluded(_ id: Int) -> Bool { rows.indices.contains(id) && rows[id].included }

    func setIncluded<S: Sequence>(_ ids: S, _ value: Bool) where S.Element == Int {
        guard phase == .ready || phase == .finished else { return }
        for id in ids where rows.indices.contains(id) { rows[id].included = value }
        dryRunSummary = nil
        scheduleRefresh()
    }

    func setAllVisible(_ value: Bool) { setIncluded(displayOrder, value) }

    // MARK: Preview (output names + notes), recomputed when settings or selection change

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            self.refreshScheduled = false
            self.refreshPreview()
        }
    }

    private func refreshPreview() {
        guard let scan, phase != .converting else { return }
        let options = settings.options
        let include = Set(rows.lazy.filter(\.included).map(\.id))
        let plan = Planner.makePlan(scan: scan, include: include, outputBase: Self.previewBase,
                                    options: options, checkDisk: false)
        var byFile: [Int: ConversionJob] = [:]
        for job in plan.jobs { byFile[job.fileIndex] = job }

        for i in rows.indices {
            let job = byFile[i]
            rows[i].output = job?.outputInFolder ?? "—"
            var notes: [String] = []
            let r = rows[i]
            if r.unreadable {
                notes.append("can't read")
            } else {
                if let sr = r.sampleRate, sr != ConversionOptions.targetSampleRate {
                    notes.append("resample \(Self.khz(sr))→44.1")
                }
                if r.isLossy { notes.append("lossy") }
                if options.strict && r.channels > 2 { notes.append("\(r.channels)ch→stereo") }
            }
            if job?.renamed == true { notes.append("renamed") }
            rows[i].notes = notes.joined(separator: ", ")
        }
        updateDisplayOrder()
    }

    private func updateDisplayOrder() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? rows : rows.filter { $0.path.localizedCaseInsensitiveContains(q) }
        displayOrder = filtered.sorted(using: sortOrder).map(\.id)
    }

    private static func khz(_ sr: Double) -> String {
        sr.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(sr / 1000))k" : String(format: "%.1fk", sr / 1000)
    }

    // MARK: Output location

    private func resolveOutputBase(scan: LibraryScan, interactive: Bool) -> URL? {
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

    func convertAll() {
        guard let scan, canConvert else { return }
        let options = settings.options
        let include = Set(rows.lazy.filter(\.included).map(\.id))
        guard let base = resolveOutputBase(scan: scan, interactive: true) else { return }

        dryRunSummary = nil
        for i in rows.indices { rows[i].status = .none }
        phase = .analyzing
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                Planner.makePlan(scan: scan, include: include, outputBase: base, options: options, checkDisk: true)
            }.value
            guard !plan.jobs.isEmpty else {
                self.phase = .ready
                self.alert = AlertMessage(title: "Nothing to convert", message: "No files are selected.")
                return
            }

            self.total = plan.jobs.count
            self.done = 0
            self.currentName = ""
            self.phase = .converting
            let jobToFile = plan.jobs.map(\.fileIndex)

            let engine = ConversionEngine()
            self.engine = engine
            let outcome = await engine.run(plan: plan, options: options) { result in
                Task { @MainActor in
                    self.done += 1
                    self.currentName = result.name
                    let fi = jobToFile[result.jobID]
                    switch result.status {
                    case .converted: self.rows[fi].status = .converted
                    case .failed(let msg): self.rows[fi].status = .failed(msg)
                    case .cancelled: self.rows[fi].status = .cancelled
                    }
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

    func runDryRun() {
        guard let scan, canConvert else { return }
        phase = .analyzing
        Task {
            await self.probeTask?.value
            self.phase = .ready
            self.refreshPreview()
            let included = self.rows.filter(\.included)
            let depths = self.settings.options.bitDepths
            let resample = included.filter { ($0.sampleRate ?? 44_100) != 44_100 }.count
            let lossy = included.filter(\.isLossy).count
            let renamed = included.filter { $0.notes.contains("renamed") }.count
            let unreadable = included.filter(\.unreadable).count
            let destination: String
            switch self.settings.saveMode {
            case .askEachTime: destination = "asked when you convert"
            case .nextToSource:
                destination = scan.groups[0].isFolder ? scan.groups[0].root.deletingLastPathComponent().path : scan.groups[0].root.path
            case .fixedFolder: destination = self.settings.fixedFolderPath.isEmpty ? "not set" : self.settings.fixedFolderPath
            }
            var parts = ["\(included.count) files → \(included.count * depths.count) WAVs ("
                         + depths.map { "\($0)-bit" }.joined(separator: " + ") + ")",
                         "\(resample) to resample", "\(lossy) lossy", "\(renamed) renamed"]
            if unreadable > 0 { parts.append("\(unreadable) unreadable — will fail") }
            self.dryRunSummary = DryRunSummary(
                text: "Dry run, nothing written: " + parts.joined(separator: " · ") + ". Destination: \(destination).")
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
