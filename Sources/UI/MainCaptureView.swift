import SwiftUI

struct MainCaptureView: View {
    @StateObject private var coordinator: CaptureCoordinator
    @ObservedObject private var sessionController: CaptureSessionController
    @State private var sessionName: String = ""

    init() {
        let coordinator = CaptureCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        _sessionController = ObservedObject(wrappedValue: coordinator.sessionController)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(controller: sessionController)
                .ignoresSafeArea()

            VStack {
                statusBar

                Spacer()

                if coordinator.isRecording {
                    Text("video: \(coordinator.videoFrameCount)  depth: \(coordinator.depthFrameCount)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                }

                recordButton
                    .padding(.bottom, 40)
            }
        }
        .onAppear { coordinator.start() }
    }

    private var statusBar: some View {
        VStack(spacing: 4) {
            lensToggle

            if !coordinator.isRecording {
                TextField("Session name", text: $sessionName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
            }

            Text(coordinator.statusMessage)
                .font(.caption)
                .padding(6)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .cornerRadius(6)

            if sessionController.lensMode == .ultrawide0_5x {
                Text(depthStatusText)
                    .font(.caption2)
                    .foregroundStyle(sessionController.depthAvailable ? .green : .orange)
            }
        }
        .padding(.top, 40)
    }

    private var depthStatusText: String {
        sessionController.depthAvailable
            ? String(format: "depth OK (hw %.2f / pressure %.2f)", sessionController.lastHardwareCost, sessionController.lastSystemPressureCost)
            : "depth unavailable on this device - video only"
    }

    private var lensToggle: some View {
        Button(action: toggleLens) {
            Text(sessionController.lensMode == .wide1x ? "1x" : "0.5x")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
        .disabled(coordinator.isRecording)
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            Circle()
                .fill(coordinator.isRecording ? Color.red : Color.white)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(Color.white, lineWidth: 4).padding(-6))
        }
    }

    private func toggleLens() {
        let newMode: LensMode = sessionController.lensMode == .wide1x ? .ultrawide0_5x : .wide1x
        coordinator.switchLensMode(to: newMode)
    }

    private func toggleRecording() {
        if coordinator.isRecording {
            coordinator.stopRecording()
        } else {
            coordinator.beginRecording(sessionName: sessionName)
        }
    }
}
