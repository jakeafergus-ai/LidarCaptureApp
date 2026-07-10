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

    func beginRecording(sessionName: String) {
        guard !isRecording else { return }
        guard let recordingSession = RecordingSession(sessionName: sessionName) else {
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

    func captureController(_ controller: CaptureSessionController, didOutput sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        guard isRecording, let recordingSession else { return }
        recordingSession.handle(sampleBuffer: sampleBuffer, depthData: depthData)

        DispatchQueue.main.async {
            self.videoFrameCount = recordingSession.frameCount
            self.depthFrameCount = recordingSession.depthFrameCount
        }
    }
}
