import CoreMotion
import Foundation

/// Records device motion (bias-corrected gyro, user acceleration + gravity, and
/// attitude quaternion) at ~100Hz to a CSV. CMDeviceMotion timestamps are seconds
/// since boot on the same host clock as camera presentation timestamps, so the
/// timestampMicros column aligns directly with video/depth timestamps downstream.
final class MotionRecorder {
    private let motionManager = CMMotionManager()
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var fileHandle: FileHandle?
    private var lineBuffer: [String] = []
    private(set) var sampleCount = 0

    static let header = "timestampMicros,rotX,rotY,rotZ,accX,accY,accZ,gravX,gravY,gravZ,quatW,quatX,quatY,quatZ\n"

    func start(fileURL: URL) {
        guard motionManager.isDeviceMotionAvailable else {
            DebugLog.shared.log("motion: device motion unavailable")
            return
        }

        FileManager.default.createFile(atPath: fileURL.path, contents: Data(Self.header.utf8))
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()

        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        motionManager.startDeviceMotionUpdates(to: operationQueue) { [weak self] motion, error in
            guard let self, let motion else {
                if let error { DebugLog.shared.log("motion error: \(error.localizedDescription)") }
                return
            }
            let micros = Int64((motion.timestamp * 1_000_000).rounded())
            let r = motion.rotationRate
            let a = motion.userAcceleration
            let g = motion.gravity
            let q = motion.attitude.quaternion
            self.lineBuffer.append("\(micros),\(r.x),\(r.y),\(r.z),\(a.x),\(a.y),\(a.z),\(g.x),\(g.y),\(g.z),\(q.w),\(q.x),\(q.y),\(q.z)")
            self.sampleCount += 1
            if self.lineBuffer.count >= 100 {
                self.flush()
            }
        }
        DebugLog.shared.log("motion: recording started at 100Hz")
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        operationQueue.addOperation { [weak self] in
            guard let self else { return }
            self.flush()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            DebugLog.shared.log("motion: stopped with \(self.sampleCount) samples")
        }
        operationQueue.waitUntilAllOperationsAreFinished()
    }

    private func flush() {
        guard !lineBuffer.isEmpty, let fileHandle else { return }
        let chunk = lineBuffer.joined(separator: "\n") + "\n"
        lineBuffer.removeAll(keepingCapacity: true)
        try? fileHandle.write(contentsOf: Data(chunk.utf8))
    }
}
