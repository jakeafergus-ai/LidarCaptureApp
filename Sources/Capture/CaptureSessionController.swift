import AVFoundation
import CoreVideo

protocol CaptureFrameSink: AnyObject {
    func captureController(_ controller: CaptureSessionController, didOutputVideo sampleBuffer: CMSampleBuffer)
    func captureController(_ controller: CaptureSessionController, didOutputCompanionVideo sampleBuffer: CMSampleBuffer)
    func captureController(_ controller: CaptureSessionController, didOutputDepth depthData: AVDepthData, timestamp: CMTime)
    func captureController(_ controller: CaptureSessionController, didDropFrame stream: String, timestamp: CMTime)
}

final class CaptureSessionController: NSObject, ObservableObject {
    @Published private(set) var session: AVCaptureSession = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let dataOutputQueue = DispatchQueue(label: "capture.dataOutputQueue", qos: .userInitiated)

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var lidarCompanionVideoOutput: AVCaptureVideoDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    // Diagnostics for the 0.5x depth investigation - updated on dataOutputQueue,
    // mirrored to diagSummary on main every ~30 video callbacks.
    private var diagVideoCallbackCount = 0
    private var diagCompanionCallbackCount = 0
    private var diagDepthPresentCount = 0
    private var diagDepthDroppedCount = 0
    private var diagCollectionCount = 0
    private var diagConfigSummary = ""

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureAngleObservation: NSKeyValueObservation?
    private var previewAngleObservation: NSKeyValueObservation?
    private var isRotationLockedForRecording = false
    private var hasPermission = false
    private var sessionObservers: [NSObjectProtocol] = []
    private var snapshotTimer: DispatchSourceTimer?
    private var activeDepthConnection: AVCaptureConnection?

    /// The device whose image is the recorded primary footage (wide in 1x mode,
    /// ultrawide in 0.5x mode) - manual exposure/WB/focus controls target it.
    private var primaryDevice: AVCaptureDevice?

    /// Set by the coordinator before (re)configuring; consumed during setup.
    var settingsSnapshot = CaptureSettingsSnapshot()

    weak var frameSink: CaptureFrameSink?

    @Published var isConfigured = false
    @Published var setupError: String?
    @Published var previewRotationAngle: CGFloat = 90
    @Published private(set) var lensMode: LensMode = .wide1x
    @Published private(set) var depthAvailable = false
    @Published private(set) var lastHardwareCost: Double = 0
    @Published private(set) var lastSystemPressureCost: Double = 0
    @Published private(set) var diagSummary = ""

    /// Factory-calibrated relative pose (rotation + translation, row-major 4x3)
    /// from the LiDAR/wide camera to the ultrawide camera, captured in multicam
    /// mode. This is exactly the lens-offset transform the downstream pipeline
    /// needs to carry wide-registered depth/poses over to the ultrawide frames.
    private(set) var lidarToUltrawideExtrinsics: [Double]?

    var currentLensPosition: Float {
        primaryDevice?.lensPosition ?? -1
    }

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    func requestPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
            // onAppear can fire more than once; rebuilding a session that is
            // already up tears down a healthy configuration mid-flight.
            if isConfigured && session.isRunning {
                DebugLog.shared.log("configure skipped - already configured and running")
                return
            }
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
        DebugLog.shared.log("switchLensMode -> \(newMode)")
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        lensMode = newMode
        if hasPermission {
            configureSession(for: newMode)
        }
        if wasRunning { startRunning() }
    }

    /// Resolution/fps changes need a session rebuild (formats are baked into the
    /// session configuration); everything else applies live via applyLiveControls.
    func reconfigureForSettingsChange() {
        guard hasPermission else { return }
        DebugLog.shared.log("reconfigure for settings change: \(settingsSnapshot.resolution.rawValue)@\(settingsSnapshot.fps)")
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        configureSession(for: lensMode)
        if wasRunning { startRunning() }
    }

    /// Applies manual exposure/WB/focus from the current settings snapshot to the
    /// primary device without rebuilding the session.
    func applyLiveControls() {
        guard let device = primaryDevice else { return }
        applyManualControls(to: device)
    }

    private func applyManualControls(to device: AVCaptureDevice) {
        let s = settingsSnapshot
        do {
            try device.lockForConfiguration()

            if s.autoExposure {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } else if device.isExposureModeSupported(.custom) {
                let format = device.activeFormat
                let requested = CMTime(value: 1, timescale: CMTimeScale(max(s.shutterDenominator.rounded(), 1)))
                let duration = CMTimeClampToRange(requested, range: CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration))
                let iso = min(max(Float(s.iso), format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: duration, iso: iso)
            }

            if s.autoWhiteBalance {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else if device.isWhiteBalanceModeSupported(.locked) {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(s.temperatureK), tint: Float(s.tint))
                var gains = device.deviceWhiteBalanceGains(for: values)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1.0), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
                device.setWhiteBalanceModeLocked(with: gains)
            }

            if s.autoFocus {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            } else if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }

            device.unlockForConfiguration()
            DebugLog.shared.log("manual controls applied: ae=\(s.autoExposure) shutter=1/\(Int(s.shutterDenominator)) iso=\(Int(s.iso)) awb=\(s.autoWhiteBalance) temp=\(Int(s.temperatureK)) tint=\(Int(s.tint)) af=\(s.autoFocus)")
        } catch {
            DebugLog.shared.log("manual controls error: \(error.localizedDescription)")
        }
    }

    private func configureSession(for mode: LensMode) {
        DebugLog.shared.log("configureSession mode=\(mode) sessionRunning=\(session.isRunning) isConfigured=\(isConfigured)")

        captureAngleObservation?.invalidate()
        previewAngleObservation?.invalidate()
        captureAngleObservation = nil
        previewAngleObservation = nil
        rotationCoordinator = nil

        // Detach the preview layer from any previous session before rebuilding.
        // A preview layer still holding a connection into the old session makes
        // the new multicam session reject its explicit preview connection, which
        // silently degraded 0.5x to the video-only fallback depending on how the
        // lens modes had been toggled before.
        previewLayer.session = nil

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

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = settingsSnapshot.stabilization ? .standard : .off
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        newSession.commitConfiguration()

        self.videoDataOutput = videoOutput
        self.depthDataOutput = depthOutput
        self.lidarCompanionVideoOutput = nil
        self.outputSynchronizer = synchronizer
        self.session = newSession
        self.activeDepthConnection = depthOutput?.connection(with: .depthData)
        self.primaryDevice = device
        applyManualControls(to: device)
        previewLayer.session = newSession
        attachSessionObservers(to: newSession)
        startSnapshotTimer()
        DebugLog.shared.log("single-cam configured: device=\(device.localizedName) withDepth=\(withDepth) depthFormatSelected=\(depthFormatSelected)")

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
            DebugLog.shared.log("multicam probe FAILED: device set not in supportedMultiCamDeviceSets - falling back")
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
            let chosenDepthPair = selectMultiCamDepthFormat(for: lidarDevice)
            let depthFormatSelected = chosenDepthPair != nil

            // Constrain the ultrawide too: left at its default (max-res, high-fps)
            // format it alone pushed systemPressureCost to 1.84 on-device.
            if let uwFormat = selectUltrawideMultiCamFormat(for: ultrawideDevice) {
                let d = CMVideoFormatDescriptionGetDimensions(uwFormat.formatDescription)
                diagConfigSummary += " | uw \(d.width)x\(d.height)@\(settingsSnapshot.fps)"
            } else {
                diagConfigSummary += " | uw default"
            }

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
            if videoConnection.isVideoStabilizationSupported {
                videoConnection.preferredVideoStabilizationMode = settingsSnapshot.stabilization ? .standard : .off
            }
            if videoConnection.isCameraIntrinsicMatrixDeliverySupported {
                videoConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            // Primary ultrawide video is delivered via its own plain delegate, not
            // the synchronizer: the synchronizer is reserved for the LiDAR device's
            // same-device video+depth pairing (the topology proven to work in 1x).
            videoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

            // Preview layer needs its own explicit connection to the same port -
            // one physical port can feed both the data output and the preview.
            previewLayer.setSessionWithNoConnection(newSession)
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

            // Wide (1x) companion video from the LiDAR device, recorded to disk as
            // a reference stream registered to the depth data. Depth generation
            // rides this device's video pipeline, and pairing depth with video
            // from the same device through the synchronizer reproduces the exact
            // topology that works reliably in 1x mode.
            guard let lidarVideoPort = lidarInput.ports(for: .video,
                                                          sourceDeviceType: lidarDevice.deviceType,
                                                          sourceDevicePosition: .back).first else {
                newSession.commitConfiguration()
                throw MultiCamSetupError.generic("No video port on LiDAR input.")
            }
            let companionOutput = AVCaptureVideoDataOutput()
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
            // Stabilization warps the image, breaking the wide video's pixel
            // registration with the depth maps - always off for the companion.
            if companionConnection.isVideoStabilizationSupported {
                companionConnection.preferredVideoStabilizationMode = .off
            }

            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [companionOutput, depthOutput])
            synchronizer.setDelegate(self, queue: dataOutputQueue)

            let hardwareCost = Double(newSession.hardwareCost)
            let systemPressureCost = Double(newSession.systemPressureCost)

            newSession.commitConfiguration()

            // Committing a multicam configuration can silently renegotiate device
            // formats, clearing an activeDepthDataFormat that was set beforehand -
            // which leaves the wide camera streaming video with no depth at all.
            // Verify it survived and re-apply if the commit reset it.
            DebugLog.shared.log("post-commit depthFormat=\(lidarDevice.activeDepthDataFormat.map { String(describing: $0) } ?? "NIL")")
            if lidarDevice.activeDepthDataFormat == nil, let pair = chosenDepthPair {
                let reapplied = apply(format: pair.videoFormat, depthFormat: pair.depthFormat, to: lidarDevice)
                DebugLog.shared.log("depth format was reset at commit - re-apply result=\(reapplied) now=\(lidarDevice.activeDepthDataFormat.map { String(describing: $0) } ?? "NIL")")
                diagConfigSummary += reapplied ? " | REAPPLIED" : " | REAPPLY FAILED"
            }

            let depthConnectionActive = depthConnection.isActive
            diagConfigSummary += String(format: " | depthConn %@ | hw %.2f pr %.2f", depthConnectionActive ? "active" : "INACTIVE", hardwareCost, systemPressureCost)
            publishDiagSummary()
            DebugLog.shared.log("multicam configured: \(diagConfigSummary)")

            DispatchQueue.main.async {
                self.lastHardwareCost = hardwareCost
                self.lastSystemPressureCost = systemPressureCost
            }

            // Only hardware cost >= 1.0 actually prevents a session from running.
            // Elevated systemPressureCost means the session runs but may throttle
            // under sustained load - a warn-and-monitor condition, not a reason to
            // silently drop depth (which is what the old stricter guard did).
            guard hardwareCost < 1.0 else {
                DebugLog.shared.log(String(format: "multicam hardware cost OVER BUDGET hw %.2f - falling back", hardwareCost))
                DispatchQueue.main.async {
                    self.setupError = String(format: "Multi-cam hardware cost over budget (%.2f) - falling back to video only.", hardwareCost)
                }
                configureSingleCameraSession(deviceType: .builtInUltraWideCamera, withDepth: false)
                return
            }
            if systemPressureCost >= 1.0 {
                DebugLog.shared.log(String(format: "multicam proceeding with elevated system pressure %.2f - may throttle when hot", systemPressureCost))
                DispatchQueue.main.async {
                    self.setupError = String(format: "High system pressure (%.2f) - capture may throttle if the phone gets hot.", systemPressureCost)
                }
            }

            self.videoDataOutput = videoOutput
            self.depthDataOutput = depthOutput
            self.lidarCompanionVideoOutput = companionOutput
            self.outputSynchronizer = synchronizer
            self.session = newSession
            self.activeDepthConnection = depthConnection
            self.primaryDevice = ultrawideDevice
            applyManualControls(to: ultrawideDevice)
            attachSessionObservers(to: newSession)
            startSnapshotTimer()

            if let extrinsicsData = AVCaptureDevice.extrinsicMatrix(from: lidarDevice, to: ultrawideDevice) {
                let floats = extrinsicsData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                lidarToUltrawideExtrinsics = floats.map(Double.init)
                DebugLog.shared.log("wide->ultrawide extrinsics captured (\(floats.count) values)")
            } else {
                lidarToUltrawideExtrinsics = nil
                DebugLog.shared.log("wide->ultrawide extrinsics unavailable")
            }

            dataOutputQueue.async {
                self.diagVideoCallbackCount = 0
                self.diagCompanionCallbackCount = 0
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
            DebugLog.shared.log("multicam setup FAILED: \(message) - falling back to ultrawide video-only")
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

    /// 1x path: picks the depth-capable format closest to the requested
    /// resolution whose frame rate covers the requested fps, then caps the frame
    /// rate to the target. Note: constraining frame durations on a depth-streaming
    /// device is documented to reduce the depth delivery rate - an accepted
    /// tradeoff for hitting the requested video fps, and visible in diagnostics.
    @discardableResult
    private func selectDepthFormat(for device: AVCaptureDevice) -> Bool {
        let target = settingsSnapshot.resolution.dimensions
        let targetFps = Double(settingsSnapshot.fps)

        let depthCapable = device.formats.filter { float32DepthFormat(in: $0) != nil }
        guard !depthCapable.isEmpty else { return false }

        func dims(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }

        let fpsCapable = depthCapable.filter { maxFrameRate(of: $0) >= targetFps }
        let pool = fpsCapable.isEmpty ? depthCapable : fpsCapable
        let chosenFormat = pool.min { lhs, rhs in
            let lDelta = abs(Int(dims(lhs).width) - Int(target.width))
            let rDelta = abs(Int(dims(rhs).width) - Int(target.width))
            if lDelta != rDelta { return lDelta < rDelta }
            return maxFrameRate(of: lhs) < maxFrameRate(of: rhs)
        }

        guard let chosenFormat, let depthFormat = float32DepthFormat(in: chosenFormat) else {
            return false
        }

        let applied = apply(format: chosenFormat, depthFormat: depthFormat, to: device)
        if applied {
            let d = dims(chosenFormat)
            DebugLog.shared.log("1x format: \(d.width)x\(d.height) maxFps=\(Int(maxFrameRate(of: chosenFormat))) (requested \(target.width)x\(target.height)@\(Int(targetFps)))")
            if maxFrameRate(of: chosenFormat) >= targetFps {
                do {
                    try device.lockForConfiguration()
                    let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    device.unlockForConfiguration()
                } catch {
                    DebugLog.shared.log("1x fps cap error: \(error.localizedDescription)")
                }
            }
        }
        return applied
    }

    /// 0.5x path: a device inside a multicam session can only use formats marked
    /// isMultiCamSupported, so the intersection of multicam-compatible and
    /// depth-capable is required. Among eligible formats the smallest resolution
    /// wins - the wide stream is only a depth-registered reference video, and
    /// larger formats burn hardware-cost budget the ultrawide stream needs. Also
    /// records format counts into the diagnostics string so on-device results
    /// show exactly what was available.
    private func selectMultiCamDepthFormat(for device: AVCaptureDevice) -> (videoFormat: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format)? {
        let allFormats = device.formats
        let multiCamFormats = allFormats.filter { $0.isMultiCamSupported }
        let depthCapable = allFormats.filter { float32DepthFormat(in: $0) != nil }
        let eligible = multiCamFormats.filter { float32DepthFormat(in: $0) != nil }

        diagConfigSummary = "fmts \(allFormats.count) mc \(multiCamFormats.count) depth \(depthCapable.count) both \(eligible.count)"

        let chosenFormat = eligible.min { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            if l.width != r.width { return l.width < r.width }
            return maxFrameRate(of: lhs) < maxFrameRate(of: rhs)
        }

        guard let chosenFormat, let depthFormat = float32DepthFormat(in: chosenFormat) else {
            publishDiagSummary()
            DebugLog.shared.log("no eligible multicam depth format: \(diagConfigSummary)")
            return nil
        }

        let dims = CMVideoFormatDescriptionGetDimensions(chosenFormat.formatDescription)
        let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
        diagConfigSummary += " | chose \(dims.width)x\(dims.height) d \(depthDims.width)x\(depthDims.height)"

        let applied = apply(format: chosenFormat, depthFormat: depthFormat, to: device)
        if !applied { diagConfigSummary += " | APPLY FAILED" }
        publishDiagSummary()
        return applied ? (chosenFormat, depthFormat) : nil
    }

    private func attachSessionObservers(to session: AVCaptureSession) {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []

        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (AVCaptureSession.runtimeErrorNotification, "runtimeError"),
            (AVCaptureSession.wasInterruptedNotification, "wasInterrupted"),
            (AVCaptureSession.interruptionEndedNotification, "interruptionEnded"),
            (AVCaptureSession.didStartRunningNotification, "didStartRunning"),
            (AVCaptureSession.didStopRunningNotification, "didStopRunning")
        ]
        for (name, label) in events {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { note in
                var detail = ""
                if let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                    detail += " error=\(error.code.rawValue) \(error.localizedDescription)"
                }
                if let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] {
                    detail += " reason=\(reason)"
                }
                DebugLog.shared.log("session \(label)\(detail)")
            })
        }
    }

    private func startSnapshotTimer() {
        snapshotTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: dataOutputQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let depthActive = self.activeDepthConnection?.isActive ?? false
            DebugLog.shared.log("snapshot running=\(self.session.isRunning) v=\(self.diagVideoCallbackCount) w=\(self.diagCompanionCallbackCount) d=\(self.diagDepthPresentCount) drop=\(self.diagDepthDroppedCount) depthConnActive=\(depthActive)")
        }
        timer.resume()
        snapshotTimer = timer
    }

    private func maxFrameRate(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    }

    /// Explicitly constrains the ultrawide's format in multicam mode - the device
    /// default is the biggest, fastest format and alone pushed system pressure to
    /// 1.84 on-device. Targets the user-requested resolution/fps, preferring the
    /// smallest adequate multicam-supported format (binned when available, since
    /// binned formats cost far less). Falls back toward closest available if the
    /// exact request has no multicam-compatible format, logging what it did.
    private func selectUltrawideMultiCamFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let target = settingsSnapshot.resolution.dimensions
        let targetFps = Double(settingsSnapshot.fps)

        let eligible = device.formats.filter { $0.isMultiCamSupported }
        func dims(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }

        let adequate = eligible.filter { dims($0).width >= target.width && maxFrameRate(of: $0) >= targetFps }
        let chosen = adequate.min { lhs, rhs in
            if dims(lhs).width != dims(rhs).width { return dims(lhs).width < dims(rhs).width }
            if lhs.isVideoBinned != rhs.isVideoBinned { return lhs.isVideoBinned }
            return maxFrameRate(of: lhs) < maxFrameRate(of: rhs)
        } ?? eligible.min { lhs, rhs in
            // Nothing meets the request - take the closest available and log it.
            let lDelta = abs(Int(dims(lhs).width) - Int(target.width))
            let rDelta = abs(Int(dims(rhs).width) - Int(target.width))
            return lDelta < rDelta
        }

        guard let chosen else {
            DebugLog.shared.log("ultrawide: no multicam-supported format found, leaving default")
            return nil
        }

        let d = dims(chosen)
        if d.width < target.width {
            DebugLog.shared.log("ultrawide: requested \(target.width)x\(target.height) has no multicam format - clamped to \(d.width)x\(d.height)")
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            let cappedFps = min(targetFps, maxFrameRate(of: chosen))
            let duration = CMTime(value: 1, timescale: CMTimeScale(cappedFps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            DebugLog.shared.log("ultrawide format set: \(d.width)x\(d.height) binned=\(chosen.isVideoBinned) capped \(Int(cappedFps))fps (requested \(target.width)x\(target.height)@\(Int(targetFps)))")
            return chosen
        } catch {
            DebugLog.shared.log("ultrawide format config error: \(error.localizedDescription)")
            return nil
        }
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
        // Both recorded video streams (primary + wide companion, when present)
        // get the same rotation so the files match orientation.
        for output in [videoDataOutput, lidarCompanionVideoOutput] {
            if let connection = output?.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
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
    // The synchronizer always pairs same-device streams: video+depth from the
    // LiDAR device (primary video in 1x mode, wide companion video in 0.5x mode).
    // Same device means aligned timestamps, so collections reliably contain both.
    // Depth is still forwarded on its own timestamp, never gated on video.
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                 didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        if let depthOutput = depthDataOutput,
           let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData {
            if syncedDepthData.depthDataWasDropped {
                diagDepthDroppedCount += 1
                frameSink?.captureController(self, didDropFrame: "depth", timestamp: syncedDepthData.timestamp)
            } else {
                diagDepthPresentCount += 1
                frameSink?.captureController(self, didOutputDepth: syncedDepthData.depthData, timestamp: syncedDepthData.timestamp)
            }
        }

        // 1x mode: the LiDAR device's video is the primary recorded stream.
        if let companionOutput = lidarCompanionVideoOutput {
            if let syncedCompanion = synchronizedDataCollection.synchronizedData(for: companionOutput) as? AVCaptureSynchronizedSampleBufferData {
                if syncedCompanion.sampleBufferWasDropped {
                    frameSink?.captureController(self, didDropFrame: "wide", timestamp: syncedCompanion.timestamp)
                } else {
                    diagCompanionCallbackCount += 1
                    frameSink?.captureController(self, didOutputCompanionVideo: syncedCompanion.sampleBuffer)
                }
            }
        } else if let videoOutput = videoDataOutput,
                  let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData {
            if syncedVideoData.sampleBufferWasDropped {
                frameSink?.captureController(self, didDropFrame: "video", timestamp: syncedVideoData.timestamp)
            } else {
                diagVideoCallbackCount += 1
                frameSink?.captureController(self, didOutputVideo: syncedVideoData.sampleBuffer)
            }
        }

        diagCollectionCount += 1
        if diagCollectionCount % 30 == 0 {
            let summary = "\(diagConfigSummary) | cb v \(diagVideoCallbackCount) w \(diagCompanionCallbackCount) d \(diagDepthPresentCount) drop \(diagDepthDroppedCount)"
            DispatchQueue.main.async { self.diagSummary = summary }
        }
    }
}

extension CaptureSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    // 0.5x mode only: the primary ultrawide stream arrives through its own plain
    // delegate, independent of the LiDAR device's synchronizer.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoDataOutput else { return }
        diagVideoCallbackCount += 1
        frameSink?.captureController(self, didOutputVideo: sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoDataOutput else { return }
        frameSink?.captureController(self, didDropFrame: "video", timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
