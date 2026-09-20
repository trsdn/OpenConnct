import XCTest

@testable import OpenConnctControl

final class LatencyProfileTests: XCTestCase {

    /// The profiles exist to trade safety for delay, so they must be ordered:
    /// lower latency may never come with a larger buffer or a deeper cushion.
    func testLowestIsSmallerThanBalancedIsSmallerThanSafe() {
        let ordered: [LatencyProfile] = [.lowest, .balanced, .safe]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(a.deviceBufferFrames, b.deviceBufferFrames)
            XCTAssertLessThan(a.ringTargetFrames, b.ringTargetFrames)
        }
    }

    /// The ring has to hold more than the block being pulled out of it, or the
    /// resampler (which needs a little more input than output) comes up short on
    /// every pull. That is the failure the priming comment in the engine records.
    func testTheCushionAlwaysExceedsTwoBlocks() {
        for profile in LatencyProfile.allCases {
            XCTAssertGreaterThanOrEqual(
                profile.ringTargetFrames, Float(2 * profile.deviceBufferFrames), "\(profile)")
        }
    }

    /// `safe` is what shipped before profiles existed. Anyone who never opens the
    /// setting keeps that behaviour only if it is exactly reproduced.
    func testSafeIsTheBehaviourThatShippedBefore() {
        XCTAssertEqual(LatencyProfile.safe.deviceBufferFrames, 512)
        XCTAssertEqual(LatencyProfile.safe.ringTargetFrames, 1536)
        XCTAssertEqual(LatencyProfile.safe.driftProportionalGain, 2.8e-6, accuracy: 1e-12)
    }

    /// The drift loop updates once per block. With smaller blocks it updates more
    /// often, which lowers the damping ratio (a / 2√b, with a = block·kp,
    /// b = block·ki), so kp is raised in step to keep the damping where it was
    /// tuned to be.
    func testDampingRatioStaysConstantAcrossBlockSizes() {
        let ki = 1.2e-9
        func damping(_ p: LatencyProfile) -> Double {
            let block = Double(p.deviceBufferFrames)
            return block * p.driftProportionalGain / (2 * (block * ki).squareRoot())
        }
        let reference = damping(.safe)
        for profile in LatencyProfile.allCases {
            XCTAssertEqual(damping(profile), reference, accuracy: reference * 0.001, "\(profile)")
        }
    }

    func testUnknownStoredValueFallsBackToSafe() {
        XCTAssertEqual(LatencyProfile(storedValue: "nonsense"), .safe)
        XCTAssertEqual(LatencyProfile(storedValue: nil), .safe)
        XCTAssertEqual(LatencyProfile(storedValue: "lowest"), .lowest)
    }
}
