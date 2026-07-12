import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var settings: CaptureSettings
    @ObservedObject var sessionController: CaptureSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(CaptureResolution.allCases) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }
                    Picker("Frame rate", selection: $settings.fps) {
                        ForEach(CaptureSettings.fpsOptions, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    Toggle("Stabilization", isOn: $settings.stabilization)
                    if settings.stabilization {
                        Text("Stabilization warps frames and hurts reconstruction accuracy - leave off for scan captures.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Picker("LiDAR capture rate", selection: $settings.lidarFps) {
                        ForEach(CaptureSettings.lidarFpsOptions, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                } header: {
                    Text("LiDAR")
                } footer: {
                    Text("Controls how many depth frames are written to disk. The sensor always streams at its native rate, so this saves storage but does not reduce hardware cost.")
                }

                Section("Exposure") {
                    Toggle("Auto exposure", isOn: $settings.autoExposure)
                    if !settings.autoExposure {
                        VStack(alignment: .leading) {
                            Text("Shutter: 1/\(Int(settings.shutterDenominator))")
                            Slider(value: $settings.shutterDenominator, in: 24...2000, step: 1)
                        }
                        VStack(alignment: .leading) {
                            Text("ISO: \(Int(settings.iso))")
                            Slider(value: $settings.iso, in: 25...3200, step: 1)
                        }
                    }
                }

                Section("White Balance") {
                    Toggle("Auto white balance", isOn: $settings.autoWhiteBalance)
                    if !settings.autoWhiteBalance {
                        VStack(alignment: .leading) {
                            Text("Temperature: \(Int(settings.temperatureK))K")
                            Slider(value: $settings.temperatureK, in: 2500...8000, step: 50)
                        }
                        VStack(alignment: .leading) {
                            Text("Tint: \(Int(settings.tint))")
                            Slider(value: $settings.tint, in: -50...50, step: 1)
                        }
                    }
                }

                Section("Focus") {
                    Toggle("Autofocus", isOn: $settings.autoFocus)
                    if !settings.autoFocus {
                        Text("Focus locks at its current position when autofocus is turned off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if sessionController.lensMode == .ultrawide0_5x {
                    Section("Measured cost (0.5x multicam)") {
                        LabeledContent("Hardware cost", value: String(format: "%.2f / 1.00", sessionController.lastHardwareCost))
                        LabeledContent("System pressure", value: String(format: "%.2f", sessionController.lastSystemPressureCost))
                        Text("Hardware cost must stay under 1.00 or capture falls back to video-only. High system pressure can throttle capture when the phone runs hot. Values update after changing resolution or frame rate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Capture Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
