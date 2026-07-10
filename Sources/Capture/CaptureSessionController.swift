import AVFoundation
import CoreVideo

protocol CaptureFrameSink: AnyObject {
    func captureController(_ controller: CaptureSessionController, didOutput sampleBuffer: CMSampleBuffer, depthData: AVDepthData?)
}

final class CaptureSessionController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let dataOutputQueue = DispatchQueue(label: "capture.dataOutputQueue", qos: .userInitiated)

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureAngleObservation: NSKeyValueObservation?
    private var previewAngleObservation: NSKeyValueObservation?
    private var isRotationLockedForRecording = false

    weak var frameSink: CaptureFrameSink?

    @Published var isConfigured = false
    @Published var setupError: String?
    @Published var previewRotationAngle: CGFloat = 90

    func requestPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    DispatchQueue.main.async { self.setupError = "Camera access denied." }
                }
            }
        default:
            DispatchQueue.main.async { self.setupError = "Camera access not authorized." }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { self.setupError = "LiDAR camera not available on this device." }
            return
        }
        self.device = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async { self.setupError = "Cannot add camera input." }
                return
            }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async { self.setupError = "Camera input error: \(error.localizedDescription)" }
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        guard session.canAddOutput(videoOutput) else {
            DispatchQueue.main.async { self.setupError = "Cannot add video output." }
            return
        }
        session.addOutput(videoOutput)
        self.videoDataOutput = videoOutput

        let depthOutput = AVCaptureDepthDataOutput()
        depthOutput.isFilteringEnabled = false
        guard session.canAddOutput(depthOutput) else {
            DispatchQueue.main.async { self.setupError = "Cannot add depth output." }
            return
        }
        session.addOutput(depthOutput)
        self.depthDataOutput = depthOutput

        if let depthFormat = device.activeFormat.supportedDepthDataFormats.first(where: {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }) {
            do {
                try device.lockForConfiguration()
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { self.setupError = "Depth format config error: \(error.localizedDescription)" }
            }
        }

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: dataOutputQueue)
        self.outputSynchronizer = synchronizer

        setUpRotationCoordinator(device: device)

        DispatchQueue.main.async { self.isConfigured = true }
    }

    private func setUpRotationCoordinator(device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator

        captureAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.applyCaptureRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        }
        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                self?.previewRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            }
        }
    }

    private func applyCaptureRotationAngle(_ angle: CGFloat) {
        guard !isRotationLockedForRecording else { return }
        guard let connection = videoDataOutput?.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Freezes the recorded video's orientation at whatever the device's current
    /// rotation is. Called right as a recording starts so mid-clip rotation doesn't
    /// tilt the file; live tracking resumes once the clip finishes.
    func lockRotationForRecording() {
        isRotationLockedForRecording = true
    }

    func unlockRotationAfterRecording() {
        isRotationLockedForRecording = false
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
            applyCaptureRotationAngle(angle)
        }
    }

    func startRunning() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopRunning() {
        guard session.isRunning else { return }
        session.stopRunning()
    }
}

extension CaptureSessionController: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                 didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let videoOutput = videoDataOutput, let depthOutput = depthDataOutput else { return }

        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideoData.sampleBufferWasDropped else { return }

        let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput)
                as? AVCaptureSynchronizedDepthData
        let depthData = (syncedDepthData?.depthDataWasDropped == false) ? syncedDepthData?.depthData : nil

        frameSink?.captureController(self, didOutput: syncedVideoData.sampleBuffer, depthData: depthData)
    }
}
