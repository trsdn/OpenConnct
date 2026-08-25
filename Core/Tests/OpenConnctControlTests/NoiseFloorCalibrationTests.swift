import XCTest
@testable import OpenConnctControl

/// The threshold arithmetic, against a table. Every branch here is a decision
/// about what to tell a user, and each one is cheaper to get right in a test
/// than in a room.
final class NoiseFloorCalibrationTests: XCTestCase {

    private let range: ClosedRange<Float> = -80...0

    private func evaluate(floor: Float, previous: Float = -45) -> NoiseFloorResult {
        NoiseFloorCalibration.evaluate(floorDB: floor,
                                       previousThresholdDB: previous,
                                       thresholdRange: range)
    }

    // MARK: - The ordinary case

    func testTheThresholdSitsTheMarginAboveTheMeasuredFloor() {
        let result = evaluate(floor: -52)
        guard case let .propose(threshold) = result.outcome else {
            return XCTFail("expected a proposal, got \(result.outcome)")
        }
        XCTAssertEqual(threshold, -46, accuracy: 0.01,
                       "-52 plus the 6 dB margin")
    }

    func testTheProposalIsRoundedToTheSliderStep() {
        let result = evaluate(floor: -52.32)
        guard case let .propose(threshold) = result.outcome else {
            return XCTFail("expected a proposal")
        }
        XCTAssertEqual(threshold, -46.5, accuracy: 0.01)
        XCTAssertEqual((threshold / NoiseFloorCalibration.stepDB).truncatingRemainder(dividingBy: 1), 0,
                       accuracy: 0.001, "lands on a step the control can represent")
    }

    /// The reason the whole feature exists. The shipped default cannot close on
    /// this machine's own hardware.
    func testTheDefaultThresholdIsBelowARealMeasuredFloorAndThisFixesIt() {
        let measuredFloor: Float = -36.7
        let shippedDefault: Float = -45
        XCTAssertLessThan(shippedDefault, measuredFloor,
                          "the default sits below the floor, so the gate can never close")

        let result = evaluate(floor: measuredFloor, previous: shippedDefault)
        guard case let .propose(threshold) = result.outcome else {
            return XCTFail("expected a proposal, got \(result.outcome)")
        }
        XCTAssertGreaterThan(threshold, measuredFloor,
                             "and the answer is above the floor, so it can")
    }

    // MARK: - Refusals

    func testARoomAsLoudAsSpeechIsRefusedRatherThanGivenAThreshold() {
        let result = evaluate(floor: -20)
        XCTAssertEqual(result.outcome, .roomTooLoud)
    }

    /// The boundary is a decision, so it is pinned. A floor exactly at the
    /// limit is refused; one hair below it is not.
    func testTheUnusableBoundaryIsExclusive() {
        XCTAssertEqual(evaluate(floor: NoiseFloorCalibration.unusableFloorDB).outcome,
                       .roomTooLoud)
        guard case .propose = evaluate(floor: NoiseFloorCalibration.unusableFloorDB - 0.5).outcome
        else { return XCTFail("just below the limit should still produce an answer") }
    }

    func testADeadChannelIsReportedAsSuchRatherThanAsAVeryQuietRoom() {
        let result = evaluate(floor: -120)
        XCTAssertEqual(result.outcome, .nothingMeasured,
                       "no room is this quiet; this is a channel producing nothing")
    }

    /// A room quiet enough to want a threshold below the control's floor is not
    /// a failure — the bottom of the range is further below the room than the
    /// margin asked for, which still gates.
    func testAnExtremelyQuietRoomIsClampedRatherThanRefused() {
        let result = evaluate(floor: -95)
        guard case let .propose(threshold) = result.outcome else {
            return XCTFail("expected a proposal, got \(result.outcome)")
        }
        XCTAssertEqual(threshold, range.lowerBound, accuracy: 0.01)
    }

    /// And the opposite end is a refusal, because a threshold above the top of
    /// the range would be silently clamped down into the speech range.
    func testAProposalAboveTheRangeIsRefusedRatherThanClamped() {
        let result = NoiseFloorCalibration.evaluate(floorDB: -10,
                                                    previousThresholdDB: -45,
                                                    thresholdRange: -80...(-30))
        XCTAssertEqual(result.outcome, .roomTooLoud,
                       "caught by the floor limit before the range even matters")

        let narrow = NoiseFloorCalibration.evaluate(floorDB: -40,
                                                    previousThresholdDB: -45,
                                                    thresholdRange: -80...(-38))
        XCTAssertEqual(narrow.outcome, .aboveRange)
    }

    // MARK: - The margin is not arbitrary

    /// The margin equals the gate's default hysteresis on purpose: the gate
    /// closes at threshold minus hysteresis, so the closing point lands back on
    /// the measured floor. A gate that opened well above the room but closed
    /// well above it too would chop the tails of words.
    func testTheClosingThresholdLandsBackOnTheMeasuredFloor() {
        let floor: Float = -52
        let defaultHysteresis: Float = 6
        guard case let .propose(threshold) = evaluate(floor: floor).outcome else {
            return XCTFail("expected a proposal")
        }
        XCTAssertEqual(threshold - defaultHysteresis, floor, accuracy: 0.01)
    }

    // MARK: - What the user is told

    func testTheResultCarriesTheMeasurementItWasDerivedFrom() {
        let result = evaluate(floor: -52.5, previous: -45)
        XCTAssertEqual(result.floorDB, -52.5, accuracy: 0.01)
        XCTAssertEqual(result.previousThresholdDB, -45, accuracy: 0.01)
    }

    func testAMeasurementThatChangesNothingSaysSo() {
        // -51 + 6 = -45, which is exactly what it already was.
        let result = evaluate(floor: -51, previous: -45)
        XCTAssertEqual(NoiseFloorCalibration.changeDescription(result), "That is what it was already set to.")
    }

    func testAMeasurementThatChangesSomethingSaysWhichWay() {
        let raised = evaluate(floor: -40, previous: -45)
        XCTAssertEqual(NoiseFloorCalibration.changeDescription(raised),
                       "That is 11.0 dB higher than the current setting.")
        let lowered = evaluate(floor: -60, previous: -45)
        XCTAssertEqual(NoiseFloorCalibration.changeDescription(lowered),
                       "That is 9.0 dB lower than the current setting.")
    }

    func testARefusalHasNothingToSayAboutAChange() {
        XCTAssertNil(NoiseFloorCalibration.changeDescription(evaluate(floor: -10)))
    }
}
