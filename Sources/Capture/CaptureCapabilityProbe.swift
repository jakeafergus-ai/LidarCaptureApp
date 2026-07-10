import AVFoundation

// Whether hardware ISP bandwidth actually allows the LiDAR depth camera and the
// ultrawide camera to run at the same time can only be answered at runtime, per
// device. This must be checked before attempting to configure the session, not
// assumed - see the 0.5x + LiDAR decision gate in the project plan.
enum CaptureCapabilityProbe {
    static func multiCamDepthPlusUltrawideSupported(lidarDevice: AVCaptureDevice, ultrawideDevice: AVCaptureDevice) -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .back
        )

        return discovery.supportedMultiCamDeviceSets.contains { deviceSet in
            deviceSet.contains(lidarDevice) && deviceSet.contains(ultrawideDevice)
        }
    }
}
