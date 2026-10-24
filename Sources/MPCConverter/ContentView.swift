import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ConverterModel
    @EnvironmentObject var settings: AppSettings
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Group {
                if model.scan == nil {
                    dropPanel
                        .padding(.horizontal, 44)
                        .padding(.vertical, 12)
                } else {
                    LibraryPanel()
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionBar
                .padding(.horizontal, 32)
                .padding(.top, 16)
            footer
                .padding(.top, 14)
                .padding(.bottom, 14)
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Theme.background)
        .overlay {
            if dropTargeted && model.scan != nil {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.acceptsDrops else { return false }
            model.load(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted && model.acceptsDrops
        }
        .task {
            // Test hook used by the CI smoke test: MPC_AUTOLOAD=/path/to/folder
            if let p = ProcessInfo.processInfo.environment["MPC_AUTOLOAD"] {
                model.load([URL(fileURLWithPath: p)])
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Undo last conversion?", isPresented: $model.confirmUndo) {
            Button("Move to Trash", role: .destructive) { model.undo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.undoSummary)
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            Text("MPC Converter")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            SettingsButton()
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(Branding.credit).foregroundStyle(Theme.secondary)
            Link(Branding.linkLabel, destination: Branding.linkURL)
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            Button { model.convertAll() } label: {
                Label(model.scan == nil || model.includedCount == model.rows.count
                      ? "Convert All" : "Convert \(model.includedCount)",
                      systemImage: "bolt.fill")
            }
            .buttonStyle(PillStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConvert)

            Button { model.runDryRun() } label: {
                Label("Dry Run", systemImage: "eye")
            }
            .buttonStyle(PillStyle(kind: .secondary))
            .disabled(!model.canConvert)

            Spacer()

            Button { model.confirmUndo = true } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(PillStyle(kind: .ghost))
            .disabled(!model.canUndo || model.isBusy)
        }
    }

    // MARK: Empty-state drop panel

    private var dropPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(dropTargeted ? Theme.accent.opacity(0.06) : Theme.panel)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Theme.stroke,
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: [8, 6]))
            if model.phase == .scanning {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Scanning…").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "waveform")
                        .font(.system(size: 50))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.bottom, 26)
                    Text("Drag folder here")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Text("or")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.vertical, 12)
                    Button("Browse") { model.browse() }
                        .buttonStyle(PillStyle(kind: .primary, compact: true))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }
}

// MARK: - Library (file list) panel

private struct LibraryPanel: View {
    @EnvironmentObject var model: ConverterModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 10) {
            statusStrip
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))

            if let summary = model.dryRunSummary {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye").foregroundStyle(Theme.accent)
                    Text(summary.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.dryRunSummary = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.12)))
            }

            toolbar
            FileTable()
        }
    }

    // Top strip: folder info / progress / result, depending on phase
    @ViewBuilder
    private var statusStrip: some View {
        switch model.phase {
        case .converting:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Converting \(min(model.done, model.total)) of \(model.total)…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    ProgressView(value: Double(min(model.done, model.total)), total: Double(max(model.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    Text(model.currentName.isEmpty ? " " : model.currentName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(PillStyle(kind: .secondary, compact: true))
                    .keyboardShortcut(.cancelAction)
            }
        case .finished:
            if let outcome = model.outcome {
                let ok = outcome.failures.isEmpty && !outcome.wasCancelled
                HStack(spacing: 14) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(ok ? Theme.success : Theme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outcome.wasCancelled
                             ? "Cancelled: \(outcome.convertedCount) of \(outcome.results.count) converted"
                             : "Converted \(outcome.convertedCount) of \(outcome.results.count) files")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(outcome.filesWritten.count) WAV files written"
                             + (outcome.failures.isEmpty ? "" : " · \(outcome.failures.count) failed (see ⚠︎ in the list)"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { model.revealOutput() }
                        .buttonStyle(PillStyle(kind: .primary, compact: true))
                    Button("Done") { model.backToReady() }
                        .buttonStyle(PillStyle(kind: .secondary, compact: true))
                }
            }
        default:
            if let scan = model.scan {
                HStack(spacing: 14) {
                    Image(systemName: scan.isSingleFolder ? "folder.fill" : "doc.on.doc.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(scan.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(infoLine(scan))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(scan.formatSummary.prefix(5))) { item in
                            Text("\(item.name) \(item.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.white.opacity(0.08)))
                        }
                    }
                    Spacer(minLength: 8)
                    if model.phase == .analyzing || model.probing {
                        ProgressView().controlSize(.small)
                    }
                    Text(settings.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                        .lineLimit(1)
                    Button("Change…") { model.browse() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                    Button("Clear") { model.clear() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
    }

    private func infoLine(_ scan: LibraryScan) -> String {
        var s = "\(scan.files.count) audio files · "
            + ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file)
        if scan.unsupportedCount > 0 { s += " · \(scan.unsupportedCount) non-audio ignored" }
        return s
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Filter files", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))

            Button("Select All") { model.setAllVisible(true) }
            Button("Select None") { model.setAllVisible(false) }
            if !model.tableSelection.isEmpty {
                Button("Check Highlighted") { model.setIncluded(model.tableSelection, true) }
                Button("Uncheck Highlighted") { model.setIncluded(model.tableSelection, false) }
            }

            Spacer()

            Text("\(model.includedCount) of \(model.rows.count) selected · "
                 + ByteCountFormatter.string(fromByteCount: model.includedBytes, countStyle: .file))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        .controlSize(.regular)
        .disabled(model.isBusy)
    }
}

// MARK: - Table

private struct FileTable: View {
    @EnvironmentObject var model: ConverterModel

    var body: some View {
        let model = self.model   // resolve once; row cells and menus get a plain reference
        Table(model.displayedRows, selection: self.$model.tableSelection, sortOrder: self.$model.sortOrder) {
            TableColumn("✓", value: \FileRow.includedSort) { (row: FileRow) in
                // Table rows don't inherit environment objects on newer macOS → pass the model explicitly.
                CheckCell(model: model, id: row.id, included: row.included)
            }
            .width(28)

            TableColumn("File", value: \FileRow.path) { (row: FileRow) in
                Text(row.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.included ? Color.white : Color.white.opacity(0.35))
                    .help(row.path)
            }
            .width(min: 200, ideal: 340)

            TableColumn("Format", value: \FileRow.format) { (row: FileRow) in
                Text(row.format)
                    .foregroundStyle(row.unreadable ? Theme.warning : Theme.secondary)
            }
            .width(min: 110, ideal: 180)

            TableColumn("Size", value: \FileRow.size) { (row: FileRow) in
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .width(min: 60, ideal: 76)

            TableColumn("Output", value: \FileRow.output) { (row: FileRow) in
                Text(row.output)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.included ? Theme.secondary : Theme.tertiary)
                    .help(row.output)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Notes", value: \FileRow.notes) { (row: FileRow) in
                Text(row.notes)
                    .lineLimit(1)
                    .foregroundStyle(Theme.secondary)
                    .help(row.notes)
            }
            .width(min: 90, ideal: 150)

            TableColumn("", value: \FileRow.statusSort) { (row: FileRow) in
                StatusCell(status: row.status)
            }
            .width(22)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Check") { model.setIncluded(ids, true) }
            Button("Uncheck") { model.setIncluded(ids, false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CheckCell: View {
    let model: ConverterModel       // plain reference, no environment lookup
    let id: Int
    let included: Bool

    var body: some View {
        Toggle("", isOn: Binding(
            get: { included },
            set: { [model, id] newValue in model.setIncluded([id], newValue) }))
            .labelsHidden()
            .toggleStyle(.checkbox)
    }
}

private struct StatusCell: View {
    let status: RowStatus

    var body: some View {
        switch status {
        case .none:
            Text("")
        case .converted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(Theme.tertiary).help("Cancelled")
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).help(msg)
        }
    }
}

// MARK: - Settings button

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { gear }
                .buttonStyle(.plain)
                .help("Settings")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { gear }
                .buttonStyle(.plain)
                .help("Settings")
        }
    }

    private var gear: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 19))
            .foregroundStyle(Theme.secondary)
    }
}
