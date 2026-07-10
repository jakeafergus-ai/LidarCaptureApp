import SwiftUI
import UIKit
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var controller: CaptureSessionController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // The session object itself can be swapped out (e.g. switching lens mode
        // rebuilds the AVCaptureSession/AVCaptureMultiCamSession), so re-attach it.
        if uiView.videoPreviewLayer.session !== controller.session {
            uiView.videoPreviewLayer.session = controller.session
        }

        let angle = controller.previewRotationAngle
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}
