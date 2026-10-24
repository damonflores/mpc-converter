import Foundation

enum LibraryScanner {
    static let supportedExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "mp4", "aac", "flac", "caf",
    ]

    static func scan(_ inputs: [URL]) -> LibraryScan {
        let fm = FileManager.default
        var groups: [ScanGroup] = []
        var files: [ScannedFile] = []
        var unsupported = 0
        var bytes: Int64 = 0
        var counts: [String: Int] = [:]
        var looseGroup: Int?
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        func add(_ url: URL, group: Int, relDirs: [String], size: Int64) {
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { unsupported += 1; return }
            files.append(ScannedFile(url: url, groupIndex: group, relativeDirs: relDirs, size: size))
            bytes += size
            counts[ext, default: 0] += 1
        }

        for input in inputs {
            let url = input.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let gi = groups.count
                groups.append(ScanGroup(name: url.lastPathComponent, root: url, isFolder: true))
                guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let f as URL in en {
                    guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    add(f, group: gi, relDirs: relativeDirs(of: f, under: url), size: Int64(v.fileSize ?? 0))
                }
            } else {
                if url.lastPathComponent.hasPrefix(".") { continue }
                if looseGroup == nil {
                    looseGroup = groups.count
                    groups.append(ScanGroup(name: "MPC Converted", root: url.deletingLastPathComponent(), isFolder: false))
                }
                let size: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                add(url, group: looseGroup!, relDirs: [], size: Int64(size))
            }
        }

        // Deterministic order → deterministic collision suffixes.
        files.sort {
            if $0.groupIndex != $1.groupIndex { return $0.groupIndex < $1.groupIndex }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        // Drop groups that ended up with no audio (keeps "N items" honest).
        return LibraryScan(groups: groups, files: files, unsupportedCount: unsupported,
                           totalBytes: bytes, countsByExtension: counts)
    }

    /// Folder components between `root` and the file (file name excluded).
    static func relativeDirs(of file: URL, under root: URL) -> [String] {
        func comps(_ f: URL, _ r: URL) -> [String]? {
            let fp = f.standardizedFileURL.pathComponents
            let rp = r.standardizedFileURL.pathComponents
            guard fp.count > rp.count, Array(fp.prefix(rp.count)) == rp else { return nil }
            return Array(fp.dropFirst(rp.count).dropLast())
        }
        if let c = comps(file, root) { return c }
        if let c = comps(file.resolvingSymlinksInPath(), root.resolvingSymlinksInPath()) { return c }
        return []
    }
}
