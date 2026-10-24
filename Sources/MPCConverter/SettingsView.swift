import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Output Bit Depths", selection: $settings.bitDepthMode) {
                    ForEach(BitDepthMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Toggle("MPC Strict Mode", isOn: $settings.strictMode)

                Toggle("Strip Metadata", isOn: Binding(
                    get: { settings.effectiveStripMetadata },
                    set: { settings.stripMetadata = $0 }))
                    .disabled(settings.strictMode)

                Toggle("Sanitize Filenames", isOn: Binding(
                    get: { settings.effectiveSanitizeFilenames },
                    set: { settings.sanitizeFilenames = $0 }))
                    .disabled(settings.strictMode)

                Toggle("Sanitize Folder Names", isOn: $settings.sanitizeFolders)

                Picker("Max Filename Length", selection: $settings.maxNameLength) {
                    ForEach(MaxNameLength.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Conversion")
            } footer: {
                Text("Strict Mode writes the most compatible WAV possible: plain PCM header with no extra chunks, at most 2 channels, metadata always stripped, and file names limited to letters, numbers, spaces, - and _. Filename length is counted without “.wav”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Save Mode", selection: $settings.saveMode) {
                    ForEach(SaveMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.saveMode == .fixedFolder {
                    HStack {
                        Text(settings.fixedFolderPath.isEmpty ? "No folder chosen" : settings.fixedFolderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } header: {
                Text("Save Directory")
            } footer: {
                Text(settings.saveMode.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Worker Threads") {
                    HStack(spacing: 6) {
                        Text("\(settings.workerThreads)").monospacedDigit()
                        Stepper("Worker Threads", value: $settings.workerThreads, in: 1...32)
                            .labelsHidden()
                    }
                }
                Toggle("Dither 16-bit Output", isOn: $settings.dither16)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Dither is only applied when 16-bit output would lose detail (lossy, float, 24-bit or resampled sources). Clean 16-bit sources stay bit-exact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 520, height: 640)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.fixedFolderPath = url.path
        }
    }
}
