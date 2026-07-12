import XCTest
@testable import LidarCaptureApp

final class DepthThrottlerTests: XCTestCase {
    private func keptCount(sensorFps: Double, targetFps: Int, seconds: Double) -> Int {
        var throttler = DepthThrottler(fps: targetFps)
        var kept = 0
        let frameCount = Int(sensorFps * seconds)
        for i in 0..<frameCount {
            if throttler.shouldKeep(timestampSeconds: Double(i) / sensorFps) {
                kept += 1
            }
        }
        return kept
    }

    func testFullRatePassesEverything() {
        XCTAssertEqual(keptCount(sensorFps: 30, targetFps: 30, seconds: 10), 300)
    }

    func testHalfRate() {
        let kept = keptCount(sensorFps: 30, targetFps: 15, seconds: 10)
        XCTAssertTrue((148...152).contains(kept), "expected ~150, got \(kept)")
    }

    func testNonIntegerRatio() {
        let kept = keptCount(sensorFps: 30, targetFps: 24, seconds: 10)
        XCTAssertTrue((235...245).contains(kept), "expected ~240, got \(kept)")
    }

    func testSparseRate() {
        let kept = keptCount(sensorFps: 30, targetFps: 6, seconds: 10)
        XCTAssertTrue((58...62).contains(kept), "expected ~60, got \(kept)")
    }

    func testStallReanchorsWithoutBurst() {
        var throttler = DepthThrottler(fps: 15)
        XCTAssertTrue(throttler.shouldKeep(timestampSeconds: 0))
        // 2-second gap (sensor stall), then frames resume at 30fps.
        XCTAssertTrue(throttler.shouldKeep(timestampSeconds: 2.0))
        // The very next sensor frame must NOT also be kept (no catch-up burst).
        XCTAssertFalse(throttler.shouldKeep(timestampSeconds: 2.033))
    }
}
