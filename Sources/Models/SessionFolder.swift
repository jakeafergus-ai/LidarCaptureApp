import Foundation

struct SessionFolder {
    let rootURL: URL
    let name: String

    var videoURL: URL { rootURL.appendingPathComponent("video.mov") }
    var depthFolderURL: URL { rootURL.appendingPathComponent("depth", isDirectory: true) }
    var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

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
        return name.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}
