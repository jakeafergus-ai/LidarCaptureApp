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

            VStack(spacing: 8) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                // Boxed, aspect-fit preview: the entire sensor frame is visible,
                // uncovered by any controls. Tap to focus when AF is off and idle.
                CameraPreviewView(controller: sessionController,
                                  focusTapEnabled: !settings.autoFocus && !coordinator.isRecording)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if !settings.autoFocus && !coordinator.isRecording {
                            Text("Tap to focus")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.5))
                                .cornerRadius(6)
                                .padding(.bottom, 8)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal, 8)

                if !coordinator.isRecording {
                    HStack {
                        storageGauge
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    if let expandedControl {
                        expandedPanel(for: expandedControl)
                            .padding(.horizontal, 12)
                    }

                    controlChipsRow
                } else {
                    recordingStats
                }

                bottomBar
                    .padding(.bottom, 16)
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

    // MARK: Top bar - session name (idle) / timer (recording) + thermal/depth HUD

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

    // MARK: Storage gauge - bottom-left while idle, moves beside the record
    // button while recording.

    private var storageGauge: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(systemStatus.freeGBText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 80, height: 4)
                Capsule()
                    .fill(systemStatus.freeFraction < 0.1 ? Color.orange : Color.green)
                    .frame(width: max(4, 80 * systemStatus.freeFraction), height: 4)
            }
        }
        .padding(8)
        .background(.black.opacity(0.55))
        .cornerRadius(8)
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
                steppedSlider(title: "Shutter 1/\(Int(settings.shutterDenominator))",
                              options: CaptureSettings.shutterOptions,
                              value: $settings.shutterDenominator) {
                    settings.autoExposure = false
                }
                steppedSlider(title: "ISO \(Int(settings.iso))",
                              options: CaptureSettings.isoOptions,
                              value: $settings.iso) {
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

    /// Slider that snaps between the given standard values (photographic stops)
    /// instead of every integer.
    private func steppedSlider(title: String, options: [Double], value: Binding<Double>, onEdit: @escaping () -> Void) -> some View {
        let indexBinding = Binding<Double>(
            get: { Double(CaptureSettings.nearestIndex(of: value.wrappedValue, in: options)) },
            set: { value.wrappedValue = options[Int($0.rounded())] }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
            Slider(value: indexBinding, in: 0...Double(options.count - 1), step: 1) { editing in
                if editing { onEdit() }
            }
        }
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

            HStack {
                if coordinator.isRecording {
                    // The storage gauge takes the Files button's spot while recording.
                    storageGauge
                        .padding(.leading, 30)
                } else {
                    filesButton
                        .padding(.leading, 30)
                }
                Spacer()
                if !coordinator.isRecording {
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
