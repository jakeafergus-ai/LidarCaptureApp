import AVFoundation

final class RecordingSession {
    let folder: SessionFolder
    private(set) var frameCount = 0
    private(set) var depthFrameCount = 0

    private let videoWriter = VideoWriter()
    private let depthWriter: DepthSidecarWriter
    private let startedAt = Date()
    private var started = false
    private let extraMetadata: [String: Any]

    init?(sessionName: String, extraMetadata: [String: Any] = [:]) {
        guard let folder = SessionFolder.create(sessionName: sessionName) else { return nil }
        self.folder = folder
        self.depthWriter = DepthSidecarWriter(depthFolderURL: folder.depthFolderURL)
        self.extraMetadata = extraMetadata
    }

    func handle(sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        if !started {
            do {
                try videoWriter.start(outputURL: folder.videoURL, formatDescription: formatDescription)
                started = true
            } catch {
                return
            }
        }

        videoWriter.append(sampleBuffer)
        frameCount += 1

        if let depthData {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            depthWriter.write(depthData, timestamp: timestamp)
            depthFrameCount = depthWriter.frameCount
        }
    }

    func finish(completion: @escaping () -> Void) {
        videoWriter.finish { [weak self] in
            self?.writeManifest()
            completion()
        }
    }

    private func writeManifest() {
        var manifest: [String: Any] = [
            "sessionName": folder.name,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "videoFrameCount": frameCount,
            "depthFrameCount": depthFrameCount
        ]
        for (key, value) in extraMetadata {
            manifest[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return }
        try? data.write(to: folder.manifestURL)
    }
}
