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
            Spacer(minLength: 18)
            dropPanel
                .frame(height: 322)
                .padding(.horizontal, 44)
            Spacer(minLength: 18)
            actionBar
                .padding(.horizontal, 32)
            footer
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(width: 824, height: 620)
        .background(Theme.background)
        .sheet(item: $model.dryRun) { report in
            DryRunSheet(report: report,
                        onClose: { model.dryRun = nil },
                        onConvert: { model.dryRun = nil; model.convertAll(settings) })
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
            Button { model.convertAll(settings) } label: {
                Label("Convert All", systemImage: "bolt.fill")
            }
            .buttonStyle(PillStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConvert)

            Button { model.runDryRun(settings) } label: {
                Label("Dry Run", systemImage: "eye")
            }
            .buttonStyle(PillStyle(kind: .secondary))
            .disabled(!model.canConvert)

            Spacer()

            Button { model.confirmUndo = true } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(PillStyle(kind: .ghost))
            .disabled(!model.canUndo || model.phase == .converting)
        }
    }

    // MARK: Drop panel

    private var dropPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(dropTargeted ? Theme.accent.opacity(0.06) : Theme.panel)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Theme.stroke,
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: [8, 6]))
            panelContent
                .padding(28)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard model.acceptsDrops else { return false }
            model.load(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted && model.acceptsDrops
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch model.phase {
        case .idle:
            IdleContent(browse: { model.browse() })
        case .scanning:
            BusyContent(text: "Scanning…")
        case .analyzing:
            BusyContent(text: "Analyzing files…")
        case .ready:
            if let scan = model.scan {
                ReadyContent(scan: scan, summary: settings.summary,
                             browse: { model.browse() }, clear: { model.clear() })
            }
        case .converting:
            ProgressContent(done: model.done, total: model.total, current: model.currentName,
                            cancel: { model.cancel() })
        case .finished:
            if let outcome = model.outcome {
                FinishedContent(outcome: outcome, reveal: { model.revealOutput() },
                                again: { model.backToReady() }, newBatch: { model.clear() })
            }
        }
    }
}

// MARK: - Panel states

private struct IdleContent: View {
    let browse: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 50, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 26)
            Text("Drag folder here")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("or")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
                .padding(.vertical, 12)
            Button("Browse", action: browse)
                .buttonStyle(PillStyle(kind: .primary, compact: true))
        }
    }
}

private struct BusyContent: View {
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct ReadyContent: View {
    let scan: LibraryScan
    let summary: String
    let browse: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: scan.isSingleFolder ? "folder.fill" : "doc.on.doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text(scan.displayName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(scan.files.count) audio file\(scan.files.count == 1 ? "" : "s") · "
                 + ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                ForEach(Array(scan.formatSummary.prefix(6))) { item in
                    Text("\(item.name) \(item.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
            }
            if scan.unsupportedCount > 0 {
                Text("\(scan.unsupportedCount) non-audio file\(scan.unsupportedCount == 1 ? "" : "s") will be ignored")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.9))
                .padding(.top, 2)
            HStack(spacing: 18) {
                Button("Change…", action: browse)
                Button("Clear", action: clear)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.top, 4)
        }
    }
}

private struct ProgressContent: View {
    let done: Int
    let total: Int
    let current: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Converting…")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(maxWidth: 440)
            Text("\(min(done, total)) of \(total) files")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            Text(current.isEmpty ? " " : current)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440)
            Button("Cancel", action: cancel)
                .buttonStyle(PillStyle(kind: .secondary, compact: true))
                .keyboardShortcut(.cancelAction)
                .padding(.top, 6)
        }
    }
}

private struct FinishedContent: View {
    let outcome: RunOutcome
    let reveal: () -> Void
    let again: () -> Void
    let newBatch: () -> Void

    var body: some View {
        let failures = outcome.failures
        let total = outcome.results.count
        VStack(spacing: 10) {
            Image(systemName: failures.isEmpty && !outcome.wasCancelled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(failures.isEmpty && !outcome.wasCancelled ? Theme.success : Theme.warning)
            Text(outcome.wasCancelled
                 ? "Cancelled — \(outcome.convertedCount) of \(total) converted"
                 : "Converted \(outcome.convertedCount) of \(total) files")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Text("\(outcome.filesWritten.count) WAV files written · "
                 + outcome.bitDepths.map { "\($0)-bit" }.joined(separator: " + ") + " · 44.1 kHz")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)

            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(failures.prefix(200).enumerated()), id: \.offset) { _, f in
                            Text("\(f.0) — \(f.1)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning.opacity(0.9))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: 560, maxHeight: 70)
            }

            HStack(spacing: 12) {
                Button("Show in Finder", action: reveal)
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                Button("Convert Again", action: again)
                    .buttonStyle(PillStyle(kind: .secondary, compact: true))
                Button("New Batch", action: newBatch)
                    .buttonStyle(PillStyle(kind: .secondary, compact: true))
            }
            .padding(.top, 6)
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

// MARK: - Dry run sheet

struct DryRunSheet: View {
    let report: DryRunReport
    let onClose: () -> Void
    let onConvert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dry Run — nothing has been written")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.rows.count) source files → \(report.wavsOut) WAV files")
                Text("Destination: \(report.destinationLabel)").lineLimit(1).truncationMode(.middle)
                Text("New folders: " + report.outputFolderNames.joined(separator: ", ")).lineLimit(2)
                Text(stats)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Table(report.rows) {
                TableColumn("Source", value: \.source)
                TableColumn("Format", value: \.sourceFormat).width(min: 120, ideal: 160)
                TableColumn("Output", value: \.output)
                TableColumn("Notes", value: \.notes).width(min: 120, ideal: 170)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Convert All", action: onConvert).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 960, height: 600)
    }

    private var stats: String {
        var parts = ["\(report.needsResample) need resampling", "\(report.lossy) lossy",
                     "\(report.renamed) renamed"]
        if report.unreadable > 0 { parts.append("\(report.unreadable) unreadable") }
        if report.unsupportedSkipped > 0 { parts.append("\(report.unsupportedSkipped) non-audio ignored") }
        return parts.joined(separator: " · ")
    }
}
