import AVFoundation
import simd

final class RecordingSession {
    let folder: SessionFolder
    private(set) var frameCount = 0
    private(set) var companionFrameCount = 0
    private(set) var depthFrameCount = 0
    private(set) var droppedVideoCount = 0
    private(set) var droppedCompanionCount = 0
    private(set) var droppedDepthCount = 0

    private let videoWriter = VideoWriter()
    private let companionWriter = VideoWriter()
    private let depthWriter: DepthSidecarWriter
    private let motionRecorder = MotionRecorder()
    private let startedAt = Date()
    private var started = false
    private var companionStarted = false
    private let extraMetadata: [String: Any]
    private let primaryBitsPerSecond: Int
    var stopDiagnostics: String?

    /// The companion (wide.mov) stream is a low-res depth-registered reference,
    /// not the priority footage - a fixed modest rate regardless of the chosen
    /// tier avoids wasting bandwidth/storage on it.
    private static let companionBitsPerSecond = 10_000_000

    private var frameLines: [String] = []
    private var frameFileHandle: FileHandle?
    private var dropLines: [String] = []
    private var dropFileHandle: FileHandle?

    init?(sessionName: String, extraMetadata: [String: Any] = [:], primaryBitsPerSecond: Int = BitrateTier.high.bitsPerSecond) {
        guard let folder = SessionFolder.create(sessionName: sessionName) else { return nil }
        self.folder = folder
        self.depthWriter = DepthSidecarWriter(depthFolderURL: folder.depthFolderURL)
        self.extraMetadata = extraMetadata
        self.primaryBitsPerSecond = primaryBitsPerSecond

        FileManager.default.createFile(atPath: folder.framesURL.path,
                                       contents: Data("timestampMicros,lensPosition,fx,fy,cx,cy\n".utf8))
        frameFileHandle = try? FileHandle(forWritingTo: folder.framesURL)
        _ = try? frameFileHandle?.seekToEnd()

        FileManager.default.createFile(atPath: folder.dropsURL.path,
                                       contents: Data("stream,timestampMicros\n".utf8))
        dropFileHandle = try? FileHandle(forWritingTo: folder.dropsURL)
        _ = try? dropFileHandle?.seekToEnd()
    }

    /// Starts the auxiliary (non-camera) capture streams - called once when
    /// recording begins.
    func startAuxiliaryCapture() {
        motionRecorder.start(fileURL: folder.motionURL)
    }

    func handleVideo(sampleBuffer: CMSampleBuffer, lensPosition: Float) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        if !started {
            do {
                try videoWriter.start(outputURL: folder.videoURL, formatDescription: formatDescription, bitsPerSecond: primaryBitsPerSecond)
                started = true
            } catch {
                return
            }
        }

        videoWriter.append(sampleBuffer)
        frameCount += 1
        logFrameMetadata(sampleBuffer: sampleBuffer, lensPosition: lensPosition)
    }

    // Per-frame record of lens position (focus breathing shifts effective
    // intrinsics - SfM/SLAM assumes they're fixed, so downstream needs to know)
    // and the primary camera's intrinsic matrix when iOS delivers it.
    private func logFrameMetadata(sampleBuffer: CMSampleBuffer, lensPosition: Float) {
        let micros = Int64((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000).rounded())

        var fx: Float = -1, fy: Float = -1, cx: Float = -1, cy: Float = -1
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil),
           CFGetTypeID(attachment) == CFDataGetTypeID() {
            let data = attachment as! CFData as Data
            if data.count >= MemoryLayout<matrix_float3x3>.size {
                let matrix = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
                fx = matrix.columns.0.x
                fy = matrix.columns.1.y
                cx = matrix.columns.2.x
                cy = matrix.columns.2.y
            }
        }

        frameLines.append("\(micros),\(lensPosition),\(fx),\(fy),\(cx),\(cy)")
        if frameLines.count >= 60 { flushFrames() }
    }

    func handleDrop(stream: String, timestamp: CMTime) {
        switch stream {
        case "video": droppedVideoCount += 1
        case "wide": droppedCompanionCount += 1
        case "depth": droppedDepthCount += 1
        default: break
        }
        let micros = Int64((CMTimeGetSeconds(timestamp) * 1_000_000).rounded())
        dropLines.append("\(stream),\(micros)")
        if dropLines.count >= 20 { flushDrops() }
    }

    // Wide (1x) reference video in 0.5x mode - registered to the depth stream
    // since both come from the LiDAR device.
    func handleCompanionVideo(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        if !companionStarted {
            do {
                try companionWriter.start(outputURL: folder.wideVideoURL, formatDescription: formatDescription, bitsPerSecond: Self.companionBitsPerSecond)
                companionStarted = true
            } catch {
                return
            }
        }

        companionWriter.append(sampleBuffer)
        companionFrameCount += 1
    }

    // Depth is written on its own clock, never gated on a video frame arriving
    // alongside it. All streams share the session clock, so timestamps stay
    // comparable downstream.
    func handleDepth(depthData: AVDepthData, timestamp: CMTime) {
        depthWriter.write(depthData, timestamp: timestamp)
        depthFrameCount = depthWriter.frameCount
    }

    func finish(completion: @escaping () -> Void) {
        motionRecorder.stop()
        flushFrames()
        flushDrops()
        try? frameFileHandle?.close()
        try? dropFileHandle?.close()

        videoWriter.finish { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.companionWriter.finish {
                self.writeManifest()
                completion()
            }
        }
    }

    private func flushFrames() {
        guard !frameLines.isEmpty, let frameFileHandle else { return }
        let chunk = frameLines.joined(separator: "\n") + "\n"
        frameLines.removeAll(keepingCapacity: true)
        try? frameFileHandle.write(contentsOf: Data(chunk.utf8))
    }

    private func flushDrops() {
        guard !dropLines.isEmpty, let dropFileHandle else { return }
        let chunk = dropLines.joined(separator: "\n") + "\n"
        dropLines.removeAll(keepingCapacity: true)
        try? dropFileHandle.write(contentsOf: Data(chunk.utf8))
    }

    private func writeManifest() {
        var manifest: [String: Any] = [
            "sessionName": folder.name,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "videoFrameCount": frameCount,
            "companionVideoFrameCount": companionFrameCount,
            "depthFrameCount": depthFrameCount,
            "droppedVideoFrames": droppedVideoCount,
            "droppedCompanionFrames": droppedCompanionCount,
            "droppedDepthFrames": droppedDepthCount,
            "motionSampleCount": motionRecorder.sampleCount,
            "timestampBase": "All timestampMicros values (video/depth/motion/drops) share the device host clock (microseconds since boot)."
        ]
        for (key, value) in extraMetadata {
            manifest[key] = value
        }
        if let stopDiagnostics {
            manifest["diagnosticsAtStop"] = stopDiagnostics
        }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return }
        try? data.write(to: folder.manifestURL)
    }
}
