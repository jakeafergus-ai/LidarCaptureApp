import Foundation

/// Appends timestamped diagnostic lines to Documents/debug_log.txt so capture
/// behavior can be inspected from the Files app after a test run - the only
/// feedback channel available without a Mac attached for live debugging.
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "debuglog.queue", qos: .utility)
    private let fileURL: URL?
    private let formatter: DateFormatter

    private init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("debug_log.txt")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [fileURL] in
            guard let fileURL else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
