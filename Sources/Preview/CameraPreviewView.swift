import SwiftUI
import UIKit
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var controller: CaptureSessionController
    /// True only when a tap should trigger manual focus (autofocus off, idle).
    var focusTapEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(previewLayer: controller.previewLayer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.focusTapEnabled = focusTapEnabled

        let angle = controller.previewRotationAngle
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    final class Coordinator {
        var controller: CaptureSessionController
        weak var view: PreviewUIView?
        var focusTapEnabled = false

        init(controller: CaptureSessionController) {
            self.controller = controller
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard focusTapEnabled, let view else { return }
            let point = gesture.location(in: view)
            controller.focus(atLayerPoint: point)
            view.showFocusReticle(at: point)
        }
    }
}

final class PreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private var reticleLayer: CALayer?

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

    /// Draws a focus square at the tap point that fades out - visible confirmation
    /// the tap registered and where the camera is focusing.
    func showFocusReticle(at point: CGPoint) {
        reticleLayer?.removeFromSuperlayer()

        let size: CGFloat = 72
        let reticle = CALayer()
        reticle.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        reticle.borderColor = UIColor.systemYellow.cgColor
        reticle.borderWidth = 1.5
        reticle.cornerRadius = 4
        layer.addSublayer(reticle)
        reticleLayer = reticle

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.3
        scale.toValue = 1.0
        scale.duration = 0.25

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = CACurrentMediaTime() + 0.7
        fade.duration = 0.5
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        reticle.add(scale, forKey: "scale")
        reticle.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak reticle] in
            if self?.reticleLayer === reticle {
                reticle?.removeFromSuperlayer()
                self?.reticleLayer = nil
            }
        }
    }
}
