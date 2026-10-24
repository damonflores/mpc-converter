import AppKit
import Foundation

/// Lightweight file log at ~/Library/Logs/MPC Converter/MPC Converter.log
/// Captures our own breadcrumbs, Swift runtime errors (stderr) and fatal signals.
enum Diagnostics {
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MPC Converter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MPC Converter.log")
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logFD: Int32 = -1

    static func start() {
        // Keep the log small: start fresh if it grew past 2 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        // Route stderr (Swift "Fatal error: …" messages land there) into the log.
        freopen(logURL.path, "a", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        logFD = fileno(stderr)

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        log("──── launch · MPC Converter \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        NSSetUncaughtExceptionHandler { e in
            Diagnostics.log("UNCAUGHT EXCEPTION \(e.name.rawValue): \(e.reason ?? "") \n\(e.callStackSymbols.joined(separator: "\n"))")
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { s in
                // async-signal-safe: raw write() only
                let msg: StaticString = "\n!!! FATAL SIGNAL — app crashed (see lines above for the last step)\n"
                if Diagnostics.logFD >= 0 {
                    _ = msg.withUTF8Buffer { write(Diagnostics.logFD, $0.baseAddress, $0.count) }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                             formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        let line = "\(ts)  \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if logFD >= 0 {
            _ = line.withCString { write(logFD, $0, strlen($0)) }
        }
    }

    static func revealLog() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }
}
