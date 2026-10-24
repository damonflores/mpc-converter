import Foundation

/// Record of what the last run created, so Undo can move exactly those items to the Trash.
struct RunManifest: Codable {
    var date: Date
    var files: [String]
    var directories: [String]
}

enum ManifestStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MPC Converter", isDirectory: true)
            .appendingPathComponent("last-run.json")
    }

    static func load() -> RunManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RunManifest.self, from: data)
    }

    static func save(_ m: RunManifest) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(m).write(to: url, options: .atomic)
        } catch {
            NSLog("MPC Converter: couldn't save undo manifest: \(error)")
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// Moves the last run's output to the Trash. Returns (items trashed, files already gone).
    @discardableResult
    static func undo() -> (trashedFiles: Int, missing: Int) {
        guard let m = load() else { return (0, 0) }
        let fm = FileManager.default
        var remaining = Set(m.files)
        var trashed = 0
        var missing = 0

        // 1. Whole folders we created that contain only our own files → trash in one go.
        for dir in m.directories.sorted(by: { $0.count < $1.count }) {
            guard fm.fileExists(atPath: dir) else { continue }
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            var ours: [String] = []
            var foreign = false
            if let en = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let f as URL in en {
                    let isFile = (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    guard isFile == true else { continue }
                    if f.lastPathComponent == ".DS_Store" { continue }
                    let p = f.standardizedFileURL.path
                    if remaining.contains(p) { ours.append(p) } else { foreign = true; break }
                }
            }
            if !foreign, (try? fm.trashItem(at: dirURL, resultingItemURL: nil)) != nil {
                trashed += ours.count
                ours.forEach { remaining.remove($0) }
            }
        }

        // 2. Anything left (files in folders that also hold other stuff).
        for path in remaining {
            if fm.fileExists(atPath: path) {
                if (try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil { trashed += 1 }
            } else {
                missing += 1
            }
        }
        clear()
        return (trashed, missing)
    }
}
