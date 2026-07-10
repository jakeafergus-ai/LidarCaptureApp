import AVFoundation
import CoreVideo

protocol CaptureFrameSink: AnyObject {
    func captureController(_ controller: CaptureSessionController, didOutputVideo sampleBuffer: CMSampleBuffer)
    func captureController(_ controller: CaptureSessionController, didOutputDepth depthData: AVDepthData, timestamp: CMTime)
}

/// Consumes and discards the LiDAR device's companion wide-video frames in 0.5x
/// mode. That stream is never recorded - it exists only because depth generation
/// rides on the device's video pipeline, which doesn't run without a consumer.
private final class DiscardingVideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

final class CaptureSessionController: NSObject, ObservableObject {
    @Published private(set) var session: AVCaptureSession = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let dataOutputQueue = DispatchQueue(label: "capture.dataOutputQueue", qos: .userInitiated)
    private let discardQueue = DispatchQueue(label: "capture.discardQueue", qos: .utility)
    private let discardDelegate = DiscardingVideoDelegate()

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var lidarCompanionVideoOutput: AVCaptureVideoDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    // Diagnostics for the 0.5x depth investigation - updated on dataOutputQueue,
    // mirrored to diagSummary on main every ~30 video callbacks.
    private var diagVideoCallbackCount = 0
    private var diagDepthPresentCount = 0
    private var diagDepthDroppedCount = 0
    private var diagCollectionCount = 0
    private var diagConfigSummary = ""

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
    @Published private(set) var diagSummary = ""

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

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
    // Single video-capable input, so automatic preview/output connection is unambiguous.

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
        var depthFormatSelected = false
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
            depthFormatSelected = selectDepthFormat(for: device)
        }

        var outputsToSync: [AVCaptureOutput] = [videoOutput]
        if let depthOutput { outputsToSync.append(depthOutput) }
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: outputsToSync)
        synchronizer.setDelegate(self, queue: dataOutputQueue)

        newSession.commitConfiguration()

        self.videoDataOutput = videoOutput
        self.depthDataOutput = depthOutput
        self.lidarCompanionVideoOutput = nil
        self.outputSynchronizer = synchronizer
        self.session = newSession
        previewLayer.session = newSession

        setUpRotationCoordinator(device: device)

        DispatchQueue.main.async {
            self.isConfigured = true
            self.depthAvailable = withDepth && depthFormatSelected
            self.lastHardwareCost = 0
            self.lastSystemPressureCost = 0
            if withDepth && !depthFormatSelected {
                self.setupError = "No depth-capable format found for \(device.localizedName)."
            }
        }
    }

    // MARK: 0.5x mode - AVCaptureMultiCamSession combining the ultrawide camera
    // (video) with the LiDAR device (depth-only, no video output requested from it).
    // Two video-capable inputs exist here, so every connection - including the
    // preview layer's - must be wired explicitly to the correct port; automatic
    // connection matching is ambiguous and silently picks the wrong one.
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

            // Pick the LiDAR device's format before wiring anything that references
            // it: only formats marked isMultiCamSupported are usable at all once a
            // device is part of a multicam session, and the depth pairing lives on
            // the video format, not a separate setting - so this has to happen
            // before any connection depending on this device's current format exists.
            let depthFormatSelected = selectMultiCamDepthFormat(for: lidarDevice)

            guard let ultrawidePort = ultrawideInput.ports(for: .video,
                                                             sourceDeviceType: ultrawideDevice.deviceType,
                                                             sourceDevicePosition: .back).first else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("No video port on ultrawide input.")
            }

            let videoOutput = AVCaptureVideoDataOutput()
            guard newSession.canAddOutput(videoOutput) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot add video output.")
            }
            newSession.addOutputWithNoConnections(videoOutput)

            let videoConnection = AVCaptureConnection(inputPorts: [ultrawidePort], output: videoOutput)
            guard newSession.canAddConnection(videoConnection) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot connect ultrawide video.")
            }
            newSession.addConnection(videoConnection)

            // Preview layer needs its own explicit connection to the same port -
            // one physical port can feed both the data output and the preview.
            let previewConnection = AVCaptureConnection(inputPort: ultrawidePort, videoPreviewLayer: previewLayer)
            guard newSession.canAddConnection(previewConnection) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot connect ultrawide preview.")
            }
            newSession.addConnection(previewConnection)

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

            // Companion wide-video stream from the LiDAR device. Never recorded -
            // depth generation is slaved to the device's video pipeline, and with
            // only the depth port connected that pipeline never runs, so no depth
            // frames are ever produced (observed on-device: session configures
            // with valid costs but zero depth callbacks).
            guard let lidarVideoPort = lidarInput.ports(for: .video,
                                                          sourceDeviceType: lidarDevice.deviceType,
                                                          sourceDevicePosition: .back).first else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("No video port on LiDAR input.")
            }
            let companionOutput = AVCaptureVideoDataOutput()
            companionOutput.alwaysDiscardsLateVideoFrames = true
            guard newSession.canAddOutput(companionOutput) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot add LiDAR companion video output.")
            }
            newSession.addOutputWithNoConnections(companionOutput)
            let companionConnection = AVCaptureConnection(inputPorts: [lidarVideoPort], output: companionOutput)
            guard newSession.canAddConnection(companionConnection) else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("Cannot connect LiDAR companion video.")
            }
            newSession.addConnection(companionConnection)
            companionOutput.setSampleBufferDelegate(discardDelegate, queue: discardQueue)

            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            synchronizer.setDelegate(self, queue: dataOutputQueue)

            let hardwareCost = Double(newSession.hardwareCost)
            let systemPressureCost = Double(newSession.systemPressureCost)

            newSession.commitConfiguration()

            let depthConnectionActive = depthConnection.isActive
            diagConfigSummary += String(format: " | depthConn %@ | hw %.2f pr %.2f", depthConnectionActive ? "active" : "INACTIVE", hardwareCost, systemPressureCost)
            publishDiagSummary()

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
            self.lidarCompanionVideoOutput = companionOutput
            self.outputSynchronizer = synchronizer
            self.session = newSession
            previewLayer.setSessionWithNoConnection(newSession)

            dataOutputQueue.async {
                self.diagVideoCallbackCount = 0
                self.diagDepthPresentCount = 0
                self.diagDepthDroppedCount = 0
                self.diagCollectionCount = 0
            }

            setUpRotationCoordinator(device: ultrawideDevice)

            DispatchQueue.main.async {
                self.isConfigured = true
                self.depthAvailable = depthFormatSelected
                if !depthFormatSelected {
                    self.setupError = "0.5x video is running, but no multicam-compatible depth format was found for the LiDAR device."
                }
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

    private func float32DepthFormat(in format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        format.supportedDepthDataFormats.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
    }

    /// 1x path: searches every format the device supports (not just its current
    /// default activeFormat) for one with a depth-capable pairing.
    @discardableResult
    private func selectDepthFormat(for device: AVCaptureDevice) -> Bool {
        let candidateFormat = float32DepthFormat(in: device.activeFormat) != nil
            ? device.activeFormat
            : device.formats.first { float32DepthFormat(in: $0) != nil }

        guard let chosenFormat = candidateFormat, let depthFormat = float32DepthFormat(in: chosenFormat) else {
            return false
        }
        return apply(format: chosenFormat, depthFormat: depthFormat, to: device)
    }

    /// 0.5x path: a device inside a multicam session can only use formats marked
    /// isMultiCamSupported, so the intersection of multicam-compatible and
    /// depth-capable is required. Among eligible formats the smallest resolution
    /// wins - the wide video stream is discarded anyway, so spending ISP bandwidth
    /// on it just burns hardware-cost budget. Also records format counts into the
    /// diagnostics string so on-device results show exactly what was available.
    private func selectMultiCamDepthFormat(for device: AVCaptureDevice) -> Bool {
        let allFormats = device.formats
        let multiCamFormats = allFormats.filter { $0.isMultiCamSupported }
        let depthCapable = allFormats.filter { float32DepthFormat(in: $0) != nil }
        let eligible = multiCamFormats.filter { float32DepthFormat(in: $0) != nil }

        diagConfigSummary = "fmts \(allFormats.count) mc \(multiCamFormats.count) depth \(depthCapable.count) both \(eligible.count)"

        let chosenFormat = eligible.min { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return l.width < r.width
        }

        guard let chosenFormat, let depthFormat = float32DepthFormat(in: chosenFormat) else {
            publishDiagSummary()
            return false
        }

        let dims = CMVideoFormatDescriptionGetDimensions(chosenFormat.formatDescription)
        let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
        diagConfigSummary += " | chose \(dims.width)x\(dims.height) d \(depthDims.width)x\(depthDims.height)"

        let applied = apply(format: chosenFormat, depthFormat: depthFormat, to: device)
        if !applied { diagConfigSummary += " | APPLY FAILED" }
        publishDiagSummary()
        return applied
    }

    private func apply(format: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format, to device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.activeDepthDataFormat = depthFormat
            device.unlockForConfiguration()
            return true
        } catch {
            DispatchQueue.main.async { self.setupError = "Depth format config error: \(error.localizedDescription)" }
            return false
        }
    }

    private func publishDiagSummary() {
        let summary = diagConfigSummary
        DispatchQueue.main.async { self.diagSummary = summary }
    }

    private func setUpRotationCoordinator(device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
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
    // Video and depth are delivered to the sink independently: in 0.5x mode they
    // come from different physical cameras whose frame timing rarely coincides,
    // so the synchronizer usually delivers depth in collections that contain no
    // ultrawide video frame at all. Requiring both in one collection silently
    // discards every depth frame (observed on-device: depth callbacks counted,
    // zero depth files written). Both devices share the session clock, so the
    // per-stream timestamps remain comparable for downstream alignment.
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                 didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        if let depthOutput = depthDataOutput,
           let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData {
            if syncedDepthData.depthDataWasDropped {
                diagDepthDroppedCount += 1
            } else {
                diagDepthPresentCount += 1
                frameSink?.captureController(self, didOutputDepth: syncedDepthData.depthData, timestamp: syncedDepthData.timestamp)
            }
        }

        if let videoOutput = videoDataOutput,
           let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
           !syncedVideoData.sampleBufferWasDropped {
            diagVideoCallbackCount += 1
            frameSink?.captureController(self, didOutputVideo: syncedVideoData.sampleBuffer)
        }

        diagCollectionCount += 1
        if diagCollectionCount % 30 == 0 {
            let summary = "\(diagConfigSummary) | cb v \(diagVideoCallbackCount) d \(diagDepthPresentCount) drop \(diagDepthDroppedCount)"
            DispatchQueue.main.async { self.diagSummary = summary }
        }
    }
}
