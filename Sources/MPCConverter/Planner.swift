import Foundation

enum Planner {
    /// Map every scanned source file to its output WAV path(s).
    /// Output layout:  <outputBase>/<Folder> - 16-bit/<same subfolders>/<name>.wav
    /// Top-level folders never overwrite anything: an existing name gets " 2", " 3"…
    static func makePlan(scan: LibraryScan, include: Set<Int>? = nil, outputBase: URL,
                         options: ConversionOptions, checkDisk: Bool) -> Plan {
        let fm = FileManager.default
        let base = outputBase.standardizedFileURL
        var claimedTop = Set<String>()
        var topURLs: [[Int: URL]] = []
        var topFolders: [URL] = []

        for g in scan.groups {
            let baseName = options.sanitizeFolders ? NameSanitizer.clean(g.name, strict: options.strict) : g.name
            var map: [Int: URL] = [:]
            for depth in options.bitDepths {
                let wanted = "\(baseName) - \(depth)-bit"
                var candidate = wanted
                var n = 2
                while claimedTop.contains(candidate.lowercased())
                        || (checkDisk && fm.fileExists(atPath: base.appendingPathComponent(candidate).path)) {
                    candidate = "\(wanted) \(n)"
                    n += 1
                }
                claimedTop.insert(candidate.lowercased())
                let url = base.appendingPathComponent(candidate, isDirectory: true)
                map[depth] = url
                topFolders.append(url)
            }
            topURLs.append(map)
        }

        var usedNames: [String: Set<String>] = [:]
        var dirSet = Set<URL>()
        var jobs: [ConversionJob] = []
        let useFileSanitizer = options.sanitizeFilenames || options.strict

        for (fileIndex, f) in scan.files.enumerated() {
            if let include, !include.contains(fileIndex) { continue }
            let g = scan.groups[f.groupIndex]
            // If the output folder sits inside the source folder, don't re-convert earlier output.
            if g.isFolder, isDescendant(base, of: g.root), isDescendant(f.url, of: base) { continue }

            let relDirs = f.relativeDirs.map { options.sanitizeFolders ? NameSanitizer.clean($0, strict: options.strict) : $0 }
            let originalStem = f.url.deletingPathExtension().lastPathComponent
            let stem = useFileSanitizer ? NameSanitizer.clean(originalStem, strict: options.strict) : originalStem

            let key = "\(f.groupIndex)|" + relDirs.joined(separator: "/").lowercased()
            var used = usedNames[key, default: []]
            var finalStem = NameSanitizer.fit(stem, suffix: "", maxLength: options.maxNameLength)
            var n = 2
            while used.contains(finalStem.lowercased()) {
                finalStem = NameSanitizer.fit(stem, suffix: "_\(n)", maxLength: options.maxNameLength)
                n += 1
            }
            used.insert(finalStem.lowercased())
            usedNames[key] = used
            let fileName = finalStem + ".wav"

            var targets: [OutputTarget] = []
            for depth in options.bitDepths {
                guard var dir = topURLs[f.groupIndex][depth] else { continue }
                for c in relDirs { dir.appendPathComponent(c, isDirectory: true) }
                dirSet.insert(dir)
                targets.append(OutputTarget(bitDepth: depth, url: dir.appendingPathComponent(fileName, isDirectory: false)))
            }

            let displaySource = ((g.isFolder ? [g.name] : []) + f.relativeDirs + [f.url.lastPathComponent]).joined(separator: "/")
            let firstTop = topURLs[f.groupIndex][options.bitDepths[0]]?.lastPathComponent ?? ""
            let displayOutput = ([firstTop] + relDirs + [fileName]).joined(separator: "/")

            jobs.append(ConversionJob(id: jobs.count, fileIndex: fileIndex, source: f.url,
                                      displaySource: displaySource, displayOutput: displayOutput,
                                      outputInFolder: (relDirs + [fileName]).joined(separator: "/"),
                                      targets: targets, renamed: finalStem != originalStem))
        }

        return Plan(jobs: jobs, directories: Array(dirSet), topFolders: topFolders)
    }

    static func isDescendant(_ a: URL, of b: URL) -> Bool {
        let ap = a.standardizedFileURL.path
        let bp = b.standardizedFileURL.path
        return ap.hasPrefix(bp.hasSuffix("/") ? bp : bp + "/")
    }
}
