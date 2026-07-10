import AVFoundation
import CoreVideo

// AVDepthData (from AVCaptureDepthDataOutput) has no per-pixel confidence map -
// that is an ARKit-only feature (ARDepthData.confidenceMap). We log the coarser
// per-frame accuracy/quality signals AVDepthData does provide instead.
final class DepthSidecarWriter {
    private let depthFolderURL: URL
    private(set) var frameCount = 0

    init(depthFolderURL: URL) {
        self.depthFolderURL = depthFolderURL
        try? FileManager.default.createDirectory(at: depthFolderURL, withIntermediateDirectories: true)
    }

    func write(_ depthData: AVDepthData, timestamp: CMTime) {
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        let timestampMicros = Int64((CMTimeGetSeconds(timestamp) * 1_000_000).rounded())
        let baseName = String(format: "depth_%06d_%lld", frameCount, timestampMicros)

        writePixelBuffer(converted.depthDataMap, baseName: baseName)
        writeMetadata(converted, timestampMicros: timestampMicros, baseName: baseName)

        frameCount += 1
    }

    private func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, baseName: String) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let data = Data(bytes: baseAddress, count: bytesPerRow * height)

        let url = depthFolderURL.appendingPathComponent(baseName + ".bin")
        try? data.write(to: url)
    }

    private func writeMetadata(_ depthData: AVDepthData, timestampMicros: Int64, baseName: String) {
        let pixelBuffer = depthData.depthDataMap
        var metadata: [String: Any] = [
            "timestampMicros": timestampMicros,
            "width": CVPixelBufferGetWidth(pixelBuffer),
            "height": CVPixelBufferGetHeight(pixelBuffer),
            "bytesPerRow": CVPixelBufferGetBytesPerRow(pixelBuffer),
            "pixelFormat": "DepthFloat32",
            "accuracy": depthData.depthDataAccuracy == .absolute ? "absolute" : "relative",
            "quality": depthData.depthDataQuality == .high ? "high" : "low",
            "isFiltered": depthData.isDepthDataFiltered
        ]

        if let calibrationData = depthData.cameraCalibrationData {
            let m = calibrationData.intrinsicMatrix
            metadata["intrinsicMatrix"] = [
                m.columns.0.x, m.columns.0.y, m.columns.0.z,
                m.columns.1.x, m.columns.1.y, m.columns.1.z,
                m.columns.2.x, m.columns.2.y, m.columns.2.z
            ]
            metadata["intrinsicMatrixReferenceDimensions"] = [
                calibrationData.intrinsicMatrixReferenceDimensions.width,
                calibrationData.intrinsicMatrixReferenceDimensions.height
            ]
            metadata["pixelSize"] = calibrationData.pixelSize
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted]) else { return }
        let url = depthFolderURL.appendingPathComponent(baseName + ".json")
        try? jsonData.write(to: url)
    }
}
