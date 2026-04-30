import Foundation

/// Lightweight file logger. Writes to
/// `~/Library/Logs/MikkelsWorkspace.log`. Logging is off by default and
/// can be toggled at runtime via the menu (or by setting the
/// `DragSnapDebug` user-default to `YES`).
///
/// Usage: `DebugLog.shared.log("something happened: \(value)")`
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "local.mikkelsworkspace.debuglog")
    private let url: URL
    private let formatter: DateFormatter

    /// Reads/writes the `DragSnapDebug` user-default. Toggling this on
    /// also truncates the existing log so each session starts clean.
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "DragSnapDebug") }
        set {
            UserDefaults.standard.set(newValue, forKey: "DragSnapDebug")
            if newValue { truncate() }
        }
    }

    var logFileURL: URL { url }

    private init() {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs,
                                                 withIntermediateDirectories: true)
        self.url = logs.appendingPathComponent("MikkelsWorkspace.log")

        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        self.formatter = f
    }

    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(formatter.string(from: Date()))  \(message())\n"
        queue.async { [url] in
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    func truncate() {
        queue.async { [url] in
            try? Data().write(to: url, options: .atomic)
        }
    }
}
