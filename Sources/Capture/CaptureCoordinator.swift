import AVFoundation
import Combine

final class CaptureCoordinator: NSObject, ObservableObject, CaptureFrameSink {
    let sessionController = CaptureSessionController()
    let settings = CaptureSettings()

    @Published var isRecording = false
    @Published var statusMessage = "Not started"
    @Published var videoFrameCount = 0
    @Published var depthFrameCount = 0

    private var recordingSession: RecordingSession?
    private var depthThrottler = DepthThrottler(fps: 30)
    private var cancellables = Set<AnyCancellable>()
    private var settingsWorkItem: DispatchWorkItem?
    private var lastAppliedSnapshot = CaptureSettingsSnapshot()

    override init() {
        super.init()
        sessionController.frameSink = self

        // Debounced so slider drags don't rebuild the session per tick; snapshot
        // comparison decides between a live re-apply and a full reconfigure.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settingsWorkItem?.cancel()
                let workItem = DispatchWorkItem { self.settingsDidChange() }
                self.settingsWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
            }
            .store(in: &cancellables)
    }

    func start() {
        lastAppliedSnapshot = settings.snapshot()
        sessionController.settingsSnapshot = lastAppliedSnapshot
        sessionController.requestPermissionAndConfigure()
        sessionController.startRunning()
    }

    private func settingsDidChange() {
        guard !isRecording else { return }
        let snapshot = settings.snapshot()
        guard snapshot != lastAppliedSnapshot else { return }

        let needsRebuild = snapshot.requiresReconfigure(comparedTo: lastAppliedSnapshot)
        sessionController.settingsSnapshot = snapshot
        lastAppliedSnapshot = snapshot

        if needsRebuild {
            sessionController.reconfigureForSettingsChange()
        } else {
            sessionController.applyLiveControls()
        }
    }

    func switchLensMode(to mode: LensMode) {
        guard !isRecording else { return }
        sessionController.switchLensMode(to: mode)
    }

    func beginRecording(sessionName: String) {
        guard !isRecording else { return }
        var extraMetadata: [String: Any] = [
            "lensMode": sessionController.lensMode == .wide1x ? "wide1x" : "ultrawide0_5x",
            "depthAvailable": sessionController.depthAvailable,
            "hardwareCost": sessionController.lastHardwareCost,
            "systemPressureCost": sessionController.lastSystemPressureCost,
            "diagnostics": sessionController.diagSummary
        ]
        for (key, value) in settings.manifestFields() {
            extraMetadata[key] = value
        }
        depthThrottler = DepthThrottler(fps: settings.lidarFps)
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
        DebugLog.shared.log("record START \(recordingSession.folder.name) depthAvailable=\(sessionController.depthAvailable) diag=\(sessionController.diagSummary)")
    }

    func stopRecording() {
        guard let recordingSession else { return }
        isRecording = false
        recordingSession.stopDiagnostics = sessionController.diagSummary
        DebugLog.shared.log("record STOP \(recordingSession.folder.name) v=\(recordingSession.frameCount) w=\(recordingSession.companionFrameCount) d=\(recordingSession.depthFrameCount) diag=\(sessionController.diagSummary)")
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
        guard depthThrottler.shouldKeep(timestampSeconds: CMTimeGetSeconds(timestamp)) else { return }
        recordingSession.handleDepth(depthData: depthData, timestamp: timestamp)

        DispatchQueue.main.async {
            self.depthFrameCount = recordingSession.depthFrameCount
        }
    }
}
