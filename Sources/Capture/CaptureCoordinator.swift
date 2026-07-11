import AVFoundation

final class CaptureCoordinator: NSObject, ObservableObject, CaptureFrameSink {
    let sessionController = CaptureSessionController()

    @Published var isRecording = false
    @Published var statusMessage = "Not started"
    @Published var videoFrameCount = 0
    @Published var depthFrameCount = 0

    private var recordingSession: RecordingSession?

    override init() {
        super.init()
        sessionController.frameSink = self
    }

    func start() {
        sessionController.requestPermissionAndConfigure()
        sessionController.startRunning()
    }

    func switchLensMode(to mode: LensMode) {
        guard !isRecording else { return }
        sessionController.switchLensMode(to: mode)
    }

    func beginRecording(sessionName: String) {
        guard !isRecording else { return }
        let extraMetadata: [String: Any] = [
            "lensMode": sessionController.lensMode == .wide1x ? "wide1x" : "ultrawide0_5x",
            "depthAvailable": sessionController.depthAvailable,
            "hardwareCost": sessionController.lastHardwareCost,
            "systemPressureCost": sessionController.lastSystemPressureCost,
            "diagnostics": sessionController.diagSummary
        ]
        guard let recordingSession = RecordingSession(sessionName: sessionName, extraMetadata: extraMetadata) else {
            statusMessage = "Failed to create session folder"
            return
        }
        sessionController.lockRotationForRecording()
        self.recordingSession = recordingSession
        videoFrameCount = 0
        depthFrameCount = 0
        isRecording = true
        statusMessage = "Recording: \(recordingSession.folder.name)"
    }

    func stopRecording() {
        guard let recordingSession else { return }
        isRecording = false
        recordingSession.finish { [weak self] in
            DispatchQueue.main.async {
                self?.statusMessage = "Saved to \(recordingSession.folder.name)"
                self?.sessionController.unlockRotationAfterRecording()
            }
        }
        self.recordingSession = nil
    }

    func captureController(_ controller: CaptureSessionController, didOutputVideo sampleBuffer: CMSampleBuffer) {
        guard isRecording, let recordingSession else { return }
        recordingSession.handleVideo(sampleBuffer: sampleBuffer)

        DispatchQueue.main.async {
            self.videoFrameCount = recordingSession.frameCount
            self.depthFrameCount = recordingSession.depthFrameCount
        }
    }

    func captureController(_ controller: CaptureSessionController, didOutputCompanionVideo sampleBuffer: CMSampleBuffer) {
        guard isRecording, let recordingSession else { return }
        recordingSession.handleCompanionVideo(sampleBuffer: sampleBuffer)
    }

    func captureController(_ controller: CaptureSessionController, didOutputDepth depthData: AVDepthData, timestamp: CMTime) {
        guard isRecording, let recordingSession else { return }
        recordingSession.handleDepth(depthData: depthData, timestamp: timestamp)

        DispatchQueue.main.async {
            self.depthFrameCount = recordingSession.depthFrameCount
        }
    }
}
