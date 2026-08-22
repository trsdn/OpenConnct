import XCTest

@testable import OpenConnctControl

/// Two real microphones' gain stages, as measured from the devices themselves
/// rather than taken from a datasheet. Kept as fixtures because the interesting
/// cases come from them having *different* ceilings.
private let wideRange = HardwareGainRange(minDB: 0, maxDB: 40, stepDB: 1)
private let narrowRange = HardwareGainRange(minDB: 0, maxDB: 24, stepDB: 1)

final class HardwareGainSplitTests: XCTestCase {

    // MARK: - The invariant that matters

    /// Whatever the split, the two halves must add back up to what the user
    /// asked for. This is the only property a listener can actually hear, so it
    /// is checked across the whole usable range rather than at a few points.
    func testTotalIsPreservedAcrossTheRange() {
        for range in [wideRange, narrowRange, HardwareGainRange(minDB: -10, maxDB: 10, stepDB: 0.5)] {
            for tenths in -300...600 {
                let total = Float(tenths) / 10
                let split = HardwareGainSplitter.settled(totalDB: total, range: range)
                let sum = (split.hardwareDB ?? 0) + split.softwareDB
                XCTAssertEqual(sum, total, accuracy: 1e-3,
                               "total \(total) dB split to \(String(describing: split))")
            }
        }
    }

    /// And it must still hold when there is no device stage at all, which is the
    /// case for most microphones.
    func testTotalIsPreservedWithoutHardware() {
        for tenths in -300...600 {
            let total = Float(tenths) / 10
            let split = HardwareGainSplitter.settled(totalDB: total, range: nil)
            XCTAssertNil(split.hardwareDB)
            XCTAssertEqual(split.softwareDB, total, accuracy: 1e-6)
        }
    }

    // MARK: - Where the gain goes

    func testGainPrefersTheDeviceWhileItLasts() {
        let split = HardwareGainSplitter.settled(totalDB: 20, range: wideRange)
        XCTAssertEqual(split.hardwareDB, 20)
        XCTAssertEqual(split.softwareDB, 0, accuracy: 1e-6)
    }

    func testGainBeyondTheDeviceMaximumSpillsIntoSoftware() {
        // 40 dB is all this device has; the remaining 10 has to be DSP.
        let split = HardwareGainSplitter.settled(totalDB: 50, range: wideRange)
        XCTAssertEqual(split.hardwareDB, 40)
        XCTAssertEqual(split.softwareDB, 10, accuracy: 1e-6)
    }

    /// Attenuation is the case that would go wrong quietly. Neither device can
    /// go below 0 dB, so a negative total must come out of the DSP entirely —
    /// and the device must be driven *to* its minimum, not left wherever it was.
    func testAttenuationIsEntirelySoftwareAndStillFloorsTheDevice() {
        let split = HardwareGainSplitter.settled(totalDB: -12, range: wideRange)
        XCTAssertEqual(split.hardwareDB, 0)
        XCTAssertEqual(split.softwareDB, -12, accuracy: 1e-6)
    }

    func testTheTwoDevicesRunOutAtDifferentPoints() {
        let onWide = HardwareGainSplitter.settled(totalDB: 30, range: wideRange)
        let onNarrow = HardwareGainSplitter.settled(totalDB: 30, range: narrowRange)
        XCTAssertEqual(onWide.hardwareDB, 30)
        XCTAssertEqual(onWide.softwareDB, 0, accuracy: 1e-6)
        XCTAssertEqual(onNarrow.hardwareDB, 24)
        XCTAssertEqual(onNarrow.softwareDB, 6, accuracy: 1e-6)
    }

    // MARK: - Quantisation

    /// The device rounds silently. If the split did not round the same way, the
    /// difference would show up as a permanent small error in the total.
    func testRequestsAreQuantisedToWhatTheDeviceCanProduce() {
        XCTAssertEqual(wideRange.quantised(26.4), 26)
        XCTAssertEqual(wideRange.quantised(26.6), 27)
        XCTAssertEqual(wideRange.quantised(-5), 0)
        XCTAssertEqual(wideRange.quantised(1000), 40)
    }

    func testQuantisationRespectsAnOffsetMinimum() {
        let odd = HardwareGainRange(minDB: -7, maxDB: 5, stepDB: 3)
        XCTAssertEqual(odd.quantised(-7), -7)
        XCTAssertEqual(odd.quantised(-5), -4)
        XCTAssertEqual(odd.quantised(4.9), 5)
        // The top of the range is not on a step boundary; it must not be exceeded.
        XCTAssertLessThanOrEqual(odd.quantised(100), 5)
    }

    func testAZeroStepMeansContinuous() {
        let smooth = HardwareGainRange(minDB: 0, maxDB: 10, stepDB: 0)
        XCTAssertEqual(smooth.quantised(3.7), 3.7, accuracy: 1e-6)
    }

    /// A negative step is nonsense; it must not produce a NaN that would reach
    /// the DSP as a gain coefficient.
    func testANegativeStepIsTreatedAsContinuous() {
        let broken = HardwareGainRange(minDB: 0, maxDB: 10, stepDB: -1)
        let q = broken.quantised(3.7)
        XCTAssertFalse(q.isNaN)
        XCTAssertEqual(q, 3.7, accuracy: 1e-6)
    }

    // MARK: - Compensation while the device is still moving

    /// The device takes up to a second to arrive. During that time the DSP must
    /// hold the difference so the level does not sag or jump.
    func testCompensationTracksTheDeviceOnTheWayUp() {
        let total: Float = 30
        // Requested 30, device still reporting its old 12.
        let midMove = HardwareGainSplitter.compensate(totalDB: total, hardwareDB: 12)
        XCTAssertEqual(midMove.softwareDB, 18, accuracy: 1e-6)
        // Arrived.
        let arrived = HardwareGainSplitter.compensate(totalDB: total, hardwareDB: 30)
        XCTAssertEqual(arrived.softwareDB, 0, accuracy: 1e-6)
    }

    func testCompensationTracksTheDeviceOnTheWayDown() {
        let total: Float = 5
        let midMove = HardwareGainSplitter.compensate(totalDB: total, hardwareDB: 30)
        XCTAssertEqual(midMove.softwareDB, -25, accuracy: 1e-6)
        let arrived = HardwareGainSplitter.compensate(totalDB: total, hardwareDB: 5)
        XCTAssertEqual(arrived.softwareDB, 0, accuracy: 1e-6)
    }

    /// Somebody else moving the gain — another application, or a control on the
    /// device — must be inaudible, because the DSP absorbs it.
    func testAnExternalChangeIsAbsorbedRatherThanFought() {
        let total: Float = 26
        var heard: [Float] = []
        for reported: Float in [26, 31, 18, 0, 40] {
            let split = HardwareGainSplitter.compensate(totalDB: total, hardwareDB: reported)
            heard.append(reported + split.softwareDB)
        }
        for value in heard {
            XCTAssertEqual(value, total, accuracy: 1e-4)
        }
    }

    /// Losing the device mid-move must fall back to doing all of it in software
    /// rather than leaving the channel quiet.
    func testUnpluggingFallsBackToFullSoftwareGain() {
        let split = HardwareGainSplitter.compensate(totalDB: 26, hardwareDB: nil)
        XCTAssertNil(split.hardwareDB)
        XCTAssertEqual(split.softwareDB, 26, accuracy: 1e-6)
    }

    // MARK: - Degenerate ranges

    /// Some devices report a range with no width. Taking it is harmless; the
    /// arithmetic must simply not divide by zero.
    func testAZeroWidthRangeIsHarmless() {
        let fixed = HardwareGainRange(minDB: 12, maxDB: 12, stepDB: 1)
        let split = HardwareGainSplitter.settled(totalDB: 20, range: fixed)
        XCTAssertEqual(split.hardwareDB, 12)
        XCTAssertEqual(split.softwareDB, 8, accuracy: 1e-6)
    }

    // MARK: - Migration

    /// The upgrade must be silent. An old trim of 0 dB on a microphone whose
    /// preamp is at 26 dB has to become a total of 26 dB — reading it as a total
    /// of 0 would drive the preamp to its floor and very nearly mute the
    /// microphone, which is what the measurement on real hardware showed.
    func testAdoptionKeepsTheAudibleLevelUnchanged() {
        for reported: Float in [0, 15, 26, 40] {
            for trim: Float in [-6, 0, 4.5] {
                let adopted = HardwareGainSplitter.adoptedTotal(
                    previousTotalDB: trim, reportedHardwareDB: reported)
                // Immediately after adoption the device has not moved, so the
                // DSP must be left applying exactly the old trim.
                let split = HardwareGainSplitter.compensate(
                    totalDB: adopted, hardwareDB: reported)
                XCTAssertEqual(split.softwareDB, trim, accuracy: 1e-4,
                               "trim \(trim) on a device at \(reported)")
            }
        }
    }
}
