import Foundation

/// Timestamp-based depth write throttling. The sensor streams at its native rate
/// regardless (throttling saves storage, not hardware cost); this decides which
/// incoming frames get persisted. Timestamp-based rather than frame-counting so
/// non-integer sensor/target ratios (e.g. 30fps sensor, 24fps target) stay
/// correct and timing jitter doesn't accumulate.
struct DepthThrottler {
    private let interval: Double
    private var nextTarget: Double?

    init(fps: Int) {
        interval = 1.0 / Double(max(fps, 1))
    }

    mutating func shouldKeep(timestampSeconds timestamp: Double) -> Bool {
        guard let target = nextTarget else {
            nextTarget = timestamp + interval
            return true
        }
        guard timestamp + 1e-9 >= target else { return false }

        // Advance the schedule; if frames stalled and we fell behind by more
        // than one interval, re-anchor on the current frame instead of
        // "catching up" with a burst.
        var newTarget = target + interval
        if timestamp >= newTarget {
            newTarget = timestamp + interval
        }
        nextTarget = newTarget
        return true
    }
}
