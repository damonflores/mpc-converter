import Foundation

/// Runs a Plan on a bounded pool of worker threads.
final class ConversionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    private let queue = OperationQueue()

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    func run(plan: Plan, options: ConversionOptions,
             progress: @escaping @Sendable (JobResult) -> Void) async -> RunOutcome {
        // Create every output folder up front (single-threaded), remembering which ones are new.
        let createdDirs: [URL]
        do {
            createdDirs = try Self.makeDirectories(plan.directories)
        } catch {
            return RunOutcome(results: [], createdDirectories: [], topFolders: plan.topFolders,
                              bitDepths: options.bitDepths, wasCancelled: false,
                              setupError: "Couldn't create output folders: \(error.localizedDescription)")
        }

        queue.maxConcurrentOperationCount = max(1, options.workerThreads)
        queue.qualityOfService = .userInitiated
        let collector = ResultCollector()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            for job in plan.jobs {
                queue.addOperation { [self] in
                    let name = job.source.lastPathComponent
                    let result: JobResult
                    if self.isCancelled {
                        result = JobResult(jobID: job.id, name: name, displaySource: job.displaySource,
                                           status: .cancelled, outputs: [])
                    } else {
                        do {
                            try AudioTranscoder.transcode(source: job.source, targets: job.targets,
                                                          options: options, isCancelled: { self.isCancelled })
                            result = JobResult(jobID: job.id, name: name, displaySource: job.displaySource,
                                               status: .converted, outputs: job.targets.map(\.url))
                        } catch TranscodeError.cancelled {
                            result = JobResult(jobID: job.id, name: name, displaySource: job.displaySource,
                                               status: .cancelled, outputs: [])
                        } catch {
                            result = JobResult(jobID: job.id, name: name, displaySource: job.displaySource,
                                               status: .failed(error.localizedDescription), outputs: [])
                        }
                    }
                    collector.add(result)
                    progress(result)
                }
            }
            // Ops are never cancelled (they check the flag instead), so the barrier always runs.
            queue.addBarrierBlock { cont.resume() }
        }

        let results = collector.all.sorted { $0.jobID < $1.jobID }
        return RunOutcome(results: results, createdDirectories: createdDirs, topFolders: plan.topFolders,
                          bitDepths: options.bitDepths, wasCancelled: isCancelled, setupError: nil)
    }

    static func makeDirectories(_ dirs: [URL]) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for d in dirs.sorted(by: { $0.path.count < $1.path.count }) {
            var missing: [URL] = []
            var cur = d.standardizedFileURL
            while !fm.fileExists(atPath: cur.path) {
                missing.append(cur)
                let parent = cur.deletingLastPathComponent()
                if parent.path == cur.path { break }
                cur = parent
            }
            if !missing.isEmpty {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                created.append(contentsOf: missing.reversed())
            }
        }
        return created
    }
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [JobResult] = []
    func add(_ r: JobResult) { lock.lock(); items.append(r); lock.unlock() }
    var all: [JobResult] { lock.lock(); defer { lock.unlock() }; return items }
}
