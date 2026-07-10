import AVFoundation
import CoreVideo

protocol CaptureFrameSink: AnyObject {
    func captureController(_ controller: CaptureSessionController, didOutput sampleBuffer: CMSampleBuffer, depthData: AVDepthData?)
}

final class CaptureSessionController: NSObject, ObservableObject {
    @Published private(set) var session: AVCaptureSession = AVCaptureSession()
    private let dataOutputQueue = DispatchQueue(label: "capture.dataOutputQueue", qos: .userInitiated)

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureAngleObservation: NSKeyValueObservation?
    private var previewAngleObservation: NSKeyValueObservation?
    private var isRotationLockedForRecording = false
    private var hasPermission = false

    weak var frameSink: CaptureFrameSink?

    @Published var isConfigured = false
    @Published var setupError: String?
    @Published var previewRotationAngle: CGFloat = 90
    @Published private(set) var lensMode: LensMode = .wide1x
    @Published private(set) var depthAvailable = false
    @Published private(set) var lastHardwareCost: Double = 0
    @Published private(set) var lastSystemPressureCost: Double = 0

    func requestPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
            configureSession(for: lensMode)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.hasPermission = granted
                if granted {
                    self.configureSession(for: self.lensMode)
                } else {
                    DispatchQueue.main.async { self.setupError = "Camera access denied." }
                }
            }
        default:
            DispatchQueue.main.async { self.setupError = "Camera access not authorized." }
        }
    }

    func switchLensMode(to newMode: LensMode) {
        guard newMode != lensMode else { return }
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        lensMode = newMode
        if hasPermission {
            configureSession(for: newMode)
        }
        if wasRunning { startRunning() }
    }

    private func configureSession(for mode: LensMode) {
        captureAngleObservation?.invalidate()
        previewAngleObservation?.invalidate()
        captureAngleObservation = nil
        previewAngleObservation = nil
        rotationCoordinator = nil

        switch mode {
        case .wide1x:
            configureSingleCameraSession(deviceType: .builtInLiDARDepthCamera, withDepth: true)
        case .ultrawide0_5x:
            configureMultiCamSession()
        }
    }

    // MARK: 1x mode - one physical device provides both wide video and LiDAR depth.
    // Also used as the ultrawide-video-only fallback when multicam isn't viable.

    private func configureSingleCameraSession(deviceType: AVCaptureDevice.DeviceType, withDepth: Bool) {
        let newSession = AVCaptureSession()
        newSession.beginConfiguration()

        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
            newSession.commitConfiguration()
            DispatchQueue.main.async { self.setupError = "Required camera not available on this device." }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else {
                newSession.commitConfiguration()
                DispatchQueue.main.async { self.setupError = "Cannot add camera input." }
                return
            }
            newSession.addInput(input)
        } catch {
            newSession.commitConfiguration()
            DispatchQueue.main.async { self.setupError = "Camera input error: \(error.localizedDescription)" }
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        guard newSession.canAddOutput(videoOutput) else {
            newSession.commitConfiguration()
            DispatchQueue.main.async { self.setupError = "Cannot add video output." }
            return
        }
        newSession.addOutput(videoOutput)

        var depthOutput: AVCaptureDepthDataOutput?
        if withDepth {
            let output = AVCaptureDepthDataOutput()
            output.isFilteringEnabled = false
            guard newSession.canAddOutput(output) else {
                newSession.commitConfiguration()
                DispatchQueue.main.async { self.setupError = "Cannot add depth output." }
                return
            }
            newSession.addOutput(output)
            depthOutput = output
            selectDepthFormat(for: device)
        }

        var outputsToSync: [AVCaptureOutput] = [videoOutput]
        if let depthOutput { outputsToSync.append(depthOutput) }
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: outputsToSync)
        synchronizer.setDelegate(self, queue: dataOutputQueue)

        newSession.commitConfiguration()

        self.videoDataOutput = videoOutput
        self.depthDataOutput = depthOutput
        self.outputSynchronizer = synchronizer
        self.session = newSession

        setUpRotationCoordinator(device: device)

        DispatchQueue.main.async {
            self.isConfigured = true
            self.depthAvailable = withDepth
            self.lastHardwareCost = 0
            self.lastSystemPressureCost = 0
        }
    }

    // MARK: 0.5x mode - AVCaptureMultiCamSession combining the ultrawide camera
    // (video) with the LiDAR device (depth-only, no video output requested from it).
    // Falls back to ultrawide-video-only if the hardware can't sustain both.

    private func configureMultiCamSession() {
        guard let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
              let ultrawideDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { self.setupError = "Required cameras not available on this device." }
            configureSingleCameraSession(deviceType: .builtInUltraWideCamera, withDepth: false)
            return
        }

        guard CaptureCapabilityProbe.multiCamDepthPlusUltrawideSupported(lidarDevice: lidarDevice, ultrawideDevice: ultrawideDevice) else {
            DispatchQueue.main.async { self.setupError = "This device can't run LiDAR depth + ultrawide video simultaneously - using video only." }
            configureSingleCameraSession(deviceType: .builtInUltraWideCamera, withDepth: false)
            return
        }

        let newSession = AVCaptureMultiCamSession()
        newSession.beginConfiguration()

        do {
            let lidarInput = try AVCaptureDeviceInput(device: lidarDevice)
            let ultrawideInput = try AVCaptureDeviceInput(device: ultrawideDevice)

            guard newSession.canAddInput(lidarInput), newSession.canAddInput(ultrawideInput) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot add multi-cam inputs.")
            }
            newSession.addInputWithNoConnections(lidarInput)
            newSession.addInputWithNoConnections(ultrawideInput)

            let videoOutput = AVCaptureVideoDataOutput()
            guard newSession.canAddOutput(videoOutput) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot add video output.")
            }
            newSession.addOutputWithNoConnections(videoOutput)

            guard let ultrawidePort = ultrawideInput.ports(for: .video,
                                                             sourceDeviceType: ultrawideDevice.deviceType,
                                                             sourceDevicePosition: .back).first else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("No video port on ultrawide input.")
            }
            let videoConnection = AVCaptureConnection(inputPorts: [ultrawidePort], output: videoOutput)
            guard newSession.canAddConnection(videoConnection) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot connect ultrawide video.")
            }
            newSession.addConnection(videoConnection)

            let depthOutput = AVCaptureDepthDataOutput()
            depthOutput.isFilteringEnabled = false
            guard newSession.canAddOutput(depthOutput) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot add depth output.")
            }
            newSession.addOutputWithNoConnections(depthOutput)

            guard let lidarDepthPort = lidarInput.ports(for: .depthData,
                                                          sourceDeviceType: lidarDevice.deviceType,
                                                          sourceDevicePosition: .back).first else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("No depth port on LiDAR input.")
            }
            let depthConnection = AVCaptureConnection(inputPorts: [lidarDepthPort], output: depthOutput)
            guard newSession.canAddConnection(depthConnection) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot connect LiDAR depth.")
            }
            newSession.addConnection(depthConnection)

            selectDepthFormat(for: lidarDevice)

            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            synchronizer.setDelegate(self, queue: dataOutputQueue)

            let hardwareCost = Double(newSession.hardwareCost)
            let systemPressureCost = Double(newSession.systemPressureCost)

            newSession.commitConfiguration()

            DispatchQueue.main.async {
                self.lastHardwareCost = hardwareCost
                self.lastSystemPressureCost = systemPressureCost
            }

            guard hardwareCost < 1.0, systemPressureCost < 1.0 else {
                DispatchQueue.main.async {
                    self.setupError = String(format: "Multi-cam over budget (hardwareCost %.2f, systemPressureCost %.2f) - falling back to video only.", hardwareCost, systemPressureCost)
                }
                configureSingleCameraSession(deviceType: .builtInUltraWideCamera, withDepth: false)
                return
            }

            self.videoDataOutput = videoOutput
            self.depthDataOutput = depthOutput
            self.outputSynchronizer = synchronizer
            self.session = newSession

            setUpRotationCoordinator(device: ultrawideDevice)

            DispatchQueue.main.async {
                self.isConfigured = true
                self.depthAvailable = true
            }
        } catch {
            let message = (error as? MultiCamSetupError)?.message ?? error.localizedDescription
            DispatchQueue.main.async { self.setupError = "Multi-cam setup failed: \(message) - using video only." }
            configureSingleCameraSession(deviceType: .builtInUltraWideCamera, withDepth: false)
        }
    }

    private enum MultiCamSetupError: Error {
        case generic(String)
        var message: String {
            switch self { case .generic(let m): return m }
        }
    }

    private func selectDepthFormat(for device: AVCaptureDevice) {
        guard let depthFormat = device.activeFormat.supportedDepthDataFormats.first(where: {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeDepthDataFormat = depthFormat
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.setupError = "Depth format config error: \(error.localizedDescription)" }
        }
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
        let sessionToStart = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionToStart.startRunning()
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
        guard let videoOutput = videoDataOutput else { return }

        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideoData.sampleBufferWasDropped else { return }

        var depthData: AVDepthData?
        if let depthOutput = depthDataOutput,
           let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepthData.depthDataWasDropped {
            depthData = syncedDepthData.depthData
        }

        frameSink?.captureController(self, didOutput: syncedVideoData.sampleBuffer, depthData: depthData)
    }
}
