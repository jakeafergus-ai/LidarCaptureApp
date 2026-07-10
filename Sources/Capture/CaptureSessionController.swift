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

    weak var frameSink: CaptureFrameSink?

    @Published var isConfigured = false
    @Published var setupError: String?

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

        DispatchQueue.main.async { self.isConfigured = true }
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
