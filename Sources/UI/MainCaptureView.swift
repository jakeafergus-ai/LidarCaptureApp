import SwiftUI

struct MainCaptureView: View {
    @StateObject private var coordinator: CaptureCoordinator
    @ObservedObject private var sessionController: CaptureSessionController
    @ObservedObject private var settings: CaptureSettings
    @StateObject private var systemStatus = SystemStatusMonitor()

    @State private var sessionName: String = ""
    @State private var showSettings = false
    @State private var showFiles = false
    @State private var expandedControl: ExpandedControl?
    @State private var showPreflightAlert = false
    @State private var preflightMessage = ""

    private enum ExpandedControl {
        case exposure, whiteBalance
    }

    init() {
        let coordinator = CaptureCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        _sessionController = ObservedObject(wrappedValue: coordinator.sessionController)
        _settings = ObservedObject(wrappedValue: coordinator.settings)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(controller: sessionController)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                Spacer()

                if !coordinator.isRecording {
                    if let expandedControl {
                        expandedPanel(for: expandedControl)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }

                    controlChipsRow
                        .padding(.bottom, 6)
                } else {
                    recordingStats
                        .padding(.bottom, 6)
                }

                bottomBar
                    .padding(.bottom, 24)
            }
        }
        .onAppear { coordinator.start() }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(settings: coordinator.settings, sessionController: sessionController)
        }
        .sheet(isPresented: $showFiles) {
            FilesBrowserView()
        }
        .alert("Start recording anyway?", isPresented: $showPreflightAlert) {
            Button("Record Anyway") { beginRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(preflightMessage)
        }
    }

    // MARK: Top bar - session name (idle) / timer (recording) + storage/thermal HUD

    private var topBar: some View {
        HStack(alignment: .top) {
            if coordinator.isRecording {
                recordingTimer
            } else {
                TextField("Session name", text: $sessionName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                    .frame(maxWidth: 220)
            }

            Spacer()

            statusHUD
        }
    }

    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(elapsedText)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.75))
                .cornerRadius(8)
        }
    }

    private var elapsedText: String {
        guard let start = coordinator.recordingStartedAt else { return "00:00" }
        let seconds = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var statusHUD: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(systemStatus.freeText)
                .foregroundStyle(.white)
            Text(systemStatus.thermalText)
                .foregroundStyle(thermalColor)
            if sessionController.lensMode == .ultrawide0_5x {
                Text(sessionController.depthAvailable ? "DEPTH OK" : "NO DEPTH")
                    .foregroundStyle(sessionController.depthAvailable ? .green : .orange)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(8)
        .background(.black.opacity(0.55))
        .cornerRadius(8)
    }

    private var thermalColor: Color {
        switch systemStatus.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .white
        }
    }

    // MARK: Control chips (idle only)

    private var controlChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("LENS", sessionController.lensMode == .wide1x ? "1x" : "0.5x") {
                    let newMode: LensMode = sessionController.lensMode == .wide1x ? .ultrawide0_5x : .wide1x
                    coordinator.switchLensMode(to: newMode)
                }
                chip("RES", settings.resolution.rawValue) {
                    settings.resolution = settings.resolution == .hd1080 ? .uhd4K : .hd1080
                }
                chip("FPS", "\(settings.fps)") {
                    let options = CaptureSettings.fpsOptions
                    let index = options.firstIndex(of: settings.fps) ?? 0
                    settings.fps = options[(index + 1) % options.count]
                }
                chip("ISO", settings.autoExposure ? "A" : "\(Int(settings.iso))", highlighted: expandedControl == .exposure) {
                    toggleExpanded(.exposure)
                }
                chip("SHUTTER", settings.autoExposure ? "A" : "1/\(Int(settings.shutterDenominator))", highlighted: expandedControl == .exposure) {
                    toggleExpanded(.exposure)
                }
                chip("WB", settings.autoWhiteBalance ? "A" : "\(Int(settings.temperatureK))K", highlighted: expandedControl == .whiteBalance) {
                    toggleExpanded(.whiteBalance)
                }
                chip("TINT", settings.autoWhiteBalance ? "A" : "\(Int(settings.tint))", highlighted: expandedControl == .whiteBalance) {
                    toggleExpanded(.whiteBalance)
                }
                chip("STAB", settings.stabilization ? "ON" : "OFF") {
                    settings.stabilization.toggle()
                }
                chip("AF", settings.autoFocus ? "ON" : "OFF") {
                    settings.autoFocus.toggle()
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ label: String, _ value: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(highlighted ? Color.white.opacity(0.3) : Color.black.opacity(0.55))
            .cornerRadius(8)
        }
    }

    private func toggleExpanded(_ control: ExpandedControl) {
        expandedControl = expandedControl == control ? nil : control
    }

    // MARK: Expanded slider panels

    @ViewBuilder
    private func expandedPanel(for control: ExpandedControl) -> some View {
        VStack(spacing: 8) {
            switch control {
            case .exposure:
                panelSlider(title: "Shutter 1/\(Int(settings.shutterDenominator))",
                            value: $settings.shutterDenominator, range: 24...2000, step: 1) {
                    settings.autoExposure = false
                }
                panelSlider(title: "ISO \(Int(settings.iso))",
                            value: $settings.iso, range: 25...3200, step: 1) {
                    settings.autoExposure = false
                }
                panelAutoButton(isAuto: settings.autoExposure) {
                    settings.autoExposure = true
                    expandedControl = nil
                }
            case .whiteBalance:
                panelSlider(title: "Temp \(Int(settings.temperatureK))K",
                            value: $settings.temperatureK, range: 2500...8000, step: 50) {
                    settings.autoWhiteBalance = false
                }
                panelSlider(title: "Tint \(Int(settings.tint))",
                            value: $settings.tint, range: -50...50, step: 1) {
                    settings.autoWhiteBalance = false
                }
                panelAutoButton(isAuto: settings.autoWhiteBalance) {
                    settings.autoWhiteBalance = true
                    expandedControl = nil
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.7))
        .cornerRadius(10)
    }

    private func panelSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, onEdit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
            Slider(value: value, in: range, step: step) { editing in
                if editing { onEdit() }
            }
        }
    }

    private func panelAutoButton(isAuto: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(isAuto ? "AUTO (active)" : "Set to AUTO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isAuto ? .green : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.white.opacity(0.15))
                .cornerRadius(8)
        }
    }

    // MARK: Recording stats + bottom bar

    private var recordingStats: some View {
        Text("video \(coordinator.videoFrameCount) · depth \(coordinator.depthFrameCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55))
            .cornerRadius(8)
    }

    private var bottomBar: some View {
        ZStack {
            recordButton

            if !coordinator.isRecording {
                HStack {
                    filesButton
                        .padding(.leading, 30)
                    Spacer()
                    settingsButton
                        .padding(.trailing, 30)
                }
            }
        }
    }

    private var filesButton: some View {
        Button {
            showFiles = true
        } label: {
            Text("Files")
                .font(.subheadline.weight(.semibold))
                .frame(width: 60, height: 44)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                .cornerRadius(22)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                if coordinator.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 34, height: 34)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 64, height: 64)
                }
            }
        }
    }

    // MARK: Recording flow with preflight check

    private func toggleRecording() {
        if coordinator.isRecording {
            coordinator.stopRecording()
            return
        }

        var issues: [String] = []
        if systemStatus.freeBytes < 2_000_000_000 {
            issues.append("Storage is low (\(systemStatus.freeText)). A 4K capture uses roughly 1 GB per minute.")
        }
        if systemStatus.thermalState == .serious || systemStatus.thermalState == .critical {
            issues.append("The phone is running hot (\(systemStatus.thermalText)) - capture may throttle or stop.")
        }

        if issues.isEmpty {
            beginRecording()
        } else {
            preflightMessage = issues.joined(separator: "\n\n")
            showPreflightAlert = true
        }
    }

    private func beginRecording() {
        expandedControl = nil
        coordinator.beginRecording(sessionName: sessionName)
    }
}
