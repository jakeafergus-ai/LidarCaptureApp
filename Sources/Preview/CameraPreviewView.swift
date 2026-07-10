import SwiftUI
import UIKit
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var controller: CaptureSessionController

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(previewLayer: controller.previewLayer)
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        let angle = controller.previewRotationAngle
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

final class PreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
