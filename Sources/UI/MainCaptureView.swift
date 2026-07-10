import SwiftUI

struct MainCaptureView: View {
    @StateObject private var coordinator = CaptureCoordinator()
    @State private var sessionName: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(controller: coordinator.sessionController)
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
        }
        .padding(.top, 40)
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            Circle()
                .fill(coordinator.isRecording ? Color.red : Color.white)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(Color.white, lineWidth: 4).padding(-6))
        }
    }

    private func toggleRecording() {
        if coordinator.isRecording {
            coordinator.stopRecording()
        } else {
            coordinator.beginRecording(sessionName: sessionName)
        }
    }
}
