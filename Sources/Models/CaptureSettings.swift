import Foundation
import CoreMedia

enum CaptureResolution: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }

    var dimensions: CMVideoDimensions {
        switch self {
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        case .uhd4K: return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

/// Value-type copy of the user settings, consumed by the capture controller.
struct CaptureSettingsSnapshot: Equatable {
    var resolution: CaptureResolution = .hd1080
    var fps: Int = 30
    var lidarFps: Int = 30
    var autoExposure = true
    var shutterDenominator: Double = 60      // shutter speed = 1/x seconds
    var iso: Double = 400
    var autoWhiteBalance = true
    var temperatureK: Double = 5000
    var tint: Double = 0
    var autoFocus = true
    var stabilization = false

    /// Changes to these require tearing down and rebuilding the capture session;
    /// everything else applies live to the running device.
    func requiresReconfigure(comparedTo other: CaptureSettingsSnapshot) -> Bool {
        resolution != other.resolution || fps != other.fps
    }
}

final class CaptureSettings: ObservableObject {
    @Published var resolution: CaptureResolution = .hd1080
    @Published var fps: Int = 30
    @Published var lidarFps: Int = 30
    @Published var autoExposure = true
    @Published var shutterDenominator: Double = 60
    @Published var iso: Double = 400
    @Published var autoWhiteBalance = true
    @Published var temperatureK: Double = 5000
    @Published var tint: Double = 0
    @Published var autoFocus = true
    @Published var stabilization = false

    static let fpsOptions = [24, 30, 60]
    static let lidarFpsOptions = [6, 12, 15, 24, 30]

    func snapshot() -> CaptureSettingsSnapshot {
        CaptureSettingsSnapshot(
            resolution: resolution,
            fps: fps,
            lidarFps: lidarFps,
            autoExposure: autoExposure,
            shutterDenominator: shutterDenominator,
            iso: iso,
            autoWhiteBalance: autoWhiteBalance,
            temperatureK: temperatureK,
            tint: tint,
            autoFocus: autoFocus,
            stabilization: stabilization
        )
    }

    func manifestFields() -> [String: Any] {
        [
            "resolution": resolution.rawValue,
            "fps": fps,
            "lidarFpsRequested": lidarFps,
            "autoExposure": autoExposure,
            "shutterDenominator": shutterDenominator,
            "iso": iso,
            "autoWhiteBalance": autoWhiteBalance,
            "temperatureK": temperatureK,
            "tint": tint,
            "autoFocus": autoFocus,
            "stabilization": stabilization
        ]
    }
}
