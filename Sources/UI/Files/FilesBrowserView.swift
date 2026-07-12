import SwiftUI
import AVKit
import UIKit
import Combine

/// Video player with an explicit centered play/pause button - the bare
/// VideoPlayer looks like a static thumbnail and it's unclear where to tap.
struct VideoPlayerBox: View {
    let url: URL
    let height: CGFloat
    @State private var player: AVPlayer
    @State private var isPlaying = false

    init(url: URL, height: CGFloat) {
        self.url = url
        self.height = height
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .frame(height: height)

            Button {
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(isPlaying ? 0.35 : 0.92))
                    .shadow(radius: 4)
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = status == .playing
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem)) { _ in
            player.seek(to: .zero)
            player.pause()
        }
        .onDisappear { player.pause() }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SessionFolderInfo: Identifiable {
    let id: String
    let url: URL
    let modified: Date
    let sizeBytes: Int64
    let hasVideo: Bool
    let hasWide: Bool
    let depthCount: Int

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct FilesBrowserView: View {
    @State private var sessions: [SessionFolderInfo] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView("No recordings yet",
                                           systemImage: "video.slash",
                                           description: Text("Sessions you record appear here."))
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(value: session.id) {
                                sessionRow(session)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let session = sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { loadSessions() }
    }

    private func sessionRow(_ session: SessionFolderInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.id)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(session.modified, style: .date)
                Text(session.sizeText)
                if session.hasVideo { Label("video", systemImage: "checkmark").labelStyle(.titleOnly) }
                if session.hasWide { Text("wide") }
                if session.depthCount > 0 { Text("depth \(session.depthCount)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadSessions() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let entries = try? fileManager.contentsOfDirectory(at: documentsURL,
                                                                  includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles]) else {
            return
        }

        var found: [SessionFolderInfo] = []
        for url in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let hasVideo = fileManager.fileExists(atPath: url.appendingPathComponent("video.mov").path)
            let hasWide = fileManager.fileExists(atPath: url.appendingPathComponent("wide.mov").path)
            let depthFiles = (try? fileManager.contentsOfDirectory(atPath: url.appendingPathComponent("depth").path)) ?? []
            let depthCount = depthFiles.filter { $0.hasSuffix(".bin") }.count

            found.append(SessionFolderInfo(id: url.lastPathComponent,
                                           url: url,
                                           modified: modified,
                                           sizeBytes: folderSize(url),
                                           hasVideo: hasVideo,
                                           hasWide: hasWide,
                                           depthCount: depthCount))
        }
        sessions = found.sorted { $0.modified > $1.modified }
    }

    private func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: sessions[index].url)
        }
        sessions.remove(atOffsets: offsets)
    }
}

struct SessionDetailView: View {
    let session: SessionFolderInfo
    @State private var manifestText: String = ""
    @State private var fileRows: [(name: String, size: String)] = []
    @State private var exportItem: ExportItem?
    @State private var isExporting = false

    var body: some View {
        List {
            if session.hasVideo {
                Section("Video") {
                    VideoPlayerBox(url: session.url.appendingPathComponent("video.mov"), height: 220)
                        .listRowInsets(EdgeInsets())
                }
            }
            if session.hasWide {
                Section("Wide reference (1x)") {
                    VideoPlayerBox(url: session.url.appendingPathComponent("wide.mov"), height: 160)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Files") {
                ForEach(fileRows, id: \.name) { row in
                    HStack {
                        Text(row.name).font(.callout)
                        Spacer()
                        Text(row.size).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !manifestText.isEmpty {
                Section("Manifest") {
                    Text(manifestText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(session.id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openInFilesApp()
                } label: {
                    Image(systemName: "folder")
                }

                if isExporting {
                    ProgressView()
                } else {
                    Button {
                        exportZip()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ActivityShareSheet(url: item.url)
        }
        .task { loadDetail() }
    }

    /// Jumps straight to this recording's folder in the iOS Files app.
    private func openInFilesApp() {
        let encodedPath = session.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.url.path
        if let url = URL(string: "shareddocuments://\(encodedPath)") {
            UIApplication.shared.open(url)
        }
    }

    /// Zips the whole session folder (via the system file coordinator, no
    /// third-party code) and hands it to the share sheet for AirDrop/OneDrive/etc.
    private func exportZip() {
        isExporting = true
        let folderURL = session.url
        DispatchQueue.global(qos: .userInitiated).async {
            var zippedURL: URL?
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(readingItemAt: folderURL, options: [.forUploading], error: &coordinatorError) { tempZipURL in
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(folderURL.lastPathComponent + ".zip")
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.copyItem(at: tempZipURL, to: destination)
                    zippedURL = destination
                } catch {
                    DebugLog.shared.log("export zip copy failed: \(error.localizedDescription)")
                }
            }
            if let coordinatorError {
                DebugLog.shared.log("export zip failed: \(coordinatorError.localizedDescription)")
            }

            DispatchQueue.main.async {
                isExporting = false
                if let zippedURL {
                    exportItem = ExportItem(url: zippedURL)
                }
            }
        }
    }

    private func loadDetail() {
        let fileManager = FileManager.default
        if let data = try? Data(contentsOf: session.url.appendingPathComponent("manifest.json")),
           let text = String(data: data, encoding: .utf8) {
            manifestText = text
        }

        var rows: [(String, String)] = []
        if let entries = try? fileManager.contentsOfDirectory(at: session.url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) {
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    let count = (try? fileManager.contentsOfDirectory(atPath: url.path))?.count ?? 0
                    rows.append((url.lastPathComponent + "/", "\(count) files"))
                } else {
                    let size = Int64(values?.totalFileAllocatedSize ?? 0)
                    rows.append((url.lastPathComponent, ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
                }
            }
        }
        fileRows = rows
    }
}
