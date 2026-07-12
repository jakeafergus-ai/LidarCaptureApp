import Foundation
import Combine

/// Live free-storage and thermal-state readings for the always-visible HUD and
/// the pre-recording check. Storage polls every 5s; thermal updates are pushed
/// by the system notification.
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?

    init() {
        refreshStorage()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStorage()
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    deinit {
        timer?.invalidate()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    private func refreshStorage() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            freeBytes = capacity
        }
    }

    var freeText: String {
        ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file) + " free"
    }

    var thermalText: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Hot"
        case .critical: return "CRITICAL"
        @unknown default: return "Unknown"
        }
    }
}
