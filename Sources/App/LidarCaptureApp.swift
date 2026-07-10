import SwiftUI

@main
struct LidarCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("LidarCaptureApp")
                    .font(.title)
                    .foregroundStyle(.white)
                Text("Toolchain check OK")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
        }
    }
}
