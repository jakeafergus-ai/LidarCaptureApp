import Foundation

struct SessionFolder {
    let rootURL: URL
    let name: String

    var videoURL: URL { rootURL.appendingPathComponent("video.mov") }
    var wideVideoURL: URL { rootURL.appendingPathComponent("wide.mov") }
    var depthFolderURL: URL { rootURL.appendingPathComponent("depth", isDirectory: true) }
    var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    var motionURL: URL { rootURL.appendingPathComponent("motion.csv") }
    var framesURL: URL { rootURL.appendingPathComponent("frames.csv") }
    var dropsURL: URL { rootURL.appendingPathComponent("drops.csv") }

    static func create(sessionName: String) -> SessionFolder? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "session" : sanitize(trimmed)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folderName = "\(base)-\(timestamp)"
        let folderURL = documentsURL.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            return SessionFolder(rootURL: folderURL, name: folderName)
        } catch {
            return nil
        }
    }

    private static func sanitize(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = name.components(separatedBy: invalidCharacters).joined(separator: "-")
        // A leading dot makes the folder hidden - invisible in the Files app,
        // which reads as "my recording vanished" (e.g. a session named ".5x ...").
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "session" : cleaned
    }

    /// Renames any session folders that were created with a hidden (dot-prefixed)
    /// name by earlier builds so they show up in the Files app again. Only touches
    /// directories that contain our own recording files.
    static func recoverHiddenSessionFolders() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let entries = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }

        for url in entries where url.lastPathComponent.hasPrefix(".") {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            let looksLikeSession = fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
                || fileManager.fileExists(atPath: url.appendingPathComponent("frames.csv").path)
                || fileManager.fileExists(atPath: url.appendingPathComponent("video.mov").path)
            guard looksLikeSession else { continue }

            var newName = url.lastPathComponent
            while newName.hasPrefix(".") { newName.removeFirst() }
            if newName.isEmpty { newName = "recovered-session" }

            var destination = documentsURL.appendingPathComponent(newName)
            if fileManager.fileExists(atPath: destination.path) {
                destination = documentsURL.appendingPathComponent("recovered-\(UUID().uuidString.prefix(8))-\(newName)")
            }

            do {
                try fileManager.moveItem(at: url, to: destination)
                DebugLog.shared.log("recovered hidden session folder: \(url.lastPathComponent) -> \(destination.lastPathComponent)")
            } catch {
                DebugLog.shared.log("failed to recover \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
