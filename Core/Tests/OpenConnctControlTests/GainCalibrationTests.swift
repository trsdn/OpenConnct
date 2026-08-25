import XCTest
@testable import OpenConnctControl

final class GainCalibrationTests: XCTestCase {

    // The band the level meter draws. Passed in rather than assumed by the
    // calibration itself; these are the production values.
    private let low: Float = -18
    private let high: Float = -6
    private let clip: Float = -1
    private let range: ClosedRange<Float> = -20...40

    /// Unless a test says otherwise, the held level sits 10 dB under the peak.
    /// That is an ordinary crest for a spoken sentence, so it stands in for
    /// "somebody actually talked" in every test that is about something else.
    private func evaluate(speech: Float,
                          sustained: Float? = nil,
                          noise: Float = -70,
                          raw: Float = -40,
                          gain: Float = 0,
                          range: ClosedRange<Float>? = nil) -> GainCalibrationResult {
        GainCalibration.evaluate(speechPeakDB: speech,
                                 sustainedSpeechDB: sustained ?? (speech - 10),
                                 noiseFloorDB: noise,
                                 rawPeakDB: raw,
                                 currentGainDB: gain,
                                 gainRange: range ?? self.range,
                                 targetLowDB: low,
                                 targetHighDB: high,
                                 clipDB: clip)
    }

    // MARK: - Percentile

    func testPercentileOfEmptyIsNil() {
        XCTAssertNil(GainCalibration.percentile([], 0.95))
    }

    func testPercentilePicksHighValueWithoutTakingTheMaximum() {
        // Nine readings of a steady voice and one door slam. A maximum would
        // report the slam; the 90th percentile must not.
        let values: [Float] = [-20, -21, -19, -20, -22, -20, -19, -21, -20, 0]
        let p = GainCalibration.percentile(values, 0.9)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, -19, accuracy: 0.001)
    }

    func testPercentileClampsOutOfRangeFractions() {
        let values: [Float] = [1, 2, 3]
        XCTAssertEqual(GainCalibration.percentile(values, -1)!, 1)
        XCTAssertEqual(GainCalibration.percentile(values, 2)!, 3)
    }

    func testPercentileOfOneValue() {
        XCTAssertEqual(GainCalibration.percentile([-33], 0.95)!, -33)
    }

    func testARoomWithTapsInItIsNotMistakenForAVoice() {
        // The numbers are from a real five seconds of nobody speaking, at
        // +31 dB of gain, in this room: the peak reached -29.7 dB off ordinary
        // creaks while the room itself sat at -36.7 dB. Comparing those two
        // gives 7 dB and proposes a gain for an empty chair. The held level is
        // the room, because a tap is not held.
        let r = evaluate(speech: -29.7, sustained: -36.0, noise: -36.7)
        XCTAssertEqual(r.outcome, .nothingHeard)
    }

    func testAVoiceIsHeardEvenWhenItsPeakIsNoLouderThanTheRoomsWorstMoment() {
        // Same peak as the test above, but held rather than touched. This is
        // the case the sustained test exists to keep: it must not become a
        // stricter version of "was there a loud moment".
        let r = evaluate(speech: -29.7, sustained: -29.9, noise: -36.7)
        XCTAssertNotEqual(r.outcome, .nothingHeard)
    }

    func testTheMiddleAndTheTopAnswerDifferentQuestions() {
        // Two seconds of a "silent" room, sampled from a peak meter, with three
        // keyboard taps in it. A high percentile reports the taps; the middle
        // reports the room. Measured on real hardware, that difference was 23 dB
        // — enough to make ordinary speech look like silence, which is exactly
        // why the noise floor uses the middle and the voice uses the top.
        let room: [Float] = [-52, -50, -51, -12, -53, -49, -11, -52, -50, -13]
        XCTAssertEqual(GainCalibration.percentile(room, 0.5)!, -50, accuracy: 0.001)
        XCTAssertEqual(GainCalibration.percentile(room, 0.95)!, -11, accuracy: 0.001)
    }

    // MARK: - The ordinary case

    func testQuietVoiceIsRaisedToTheMiddleOfTheBand() {
        let r = evaluate(speech: -27, gain: 10)
        guard case let .adjust(newGain, resulting) = r.outcome else {
            return XCTFail("expected an adjustment, got \(r.outcome)")
        }
        // Middle of -18…-6 is -12, so the voice needs +15 dB on top of the 10
        // it already has.
        XCTAssertEqual(newGain, 25, accuracy: 0.001)
        XCTAssertEqual(resulting, -12, accuracy: 0.001)
    }

    func testLoudVoiceIsBroughtDown() {
        let r = evaluate(speech: -3, raw: -20, gain: 20)
        guard case let .adjust(newGain, resulting) = r.outcome else {
            return XCTFail("expected an adjustment, got \(r.outcome)")
        }
        XCTAssertEqual(newGain, 11, accuracy: 0.001)
        XCTAssertEqual(resulting, -12, accuracy: 0.001)
    }

    func testProposalIsRoundedToAHalfDecibel() {
        let r = evaluate(speech: -27.31, gain: 0)
        guard case let .adjust(newGain, _) = r.outcome else {
            return XCTFail("expected an adjustment, got \(r.outcome)")
        }
        XCTAssertEqual(newGain * 2, (newGain * 2).rounded(), accuracy: 0.0001,
                       "gain proposals finer than half a decibel are invented precision")
    }

    // MARK: - Already correct

    func testVoiceInsideTheBandIsLeftAlone() {
        for speech: Float in [-18, -15, -12, -7] {
            XCTAssertEqual(evaluate(speech: speech).outcome, .alreadyGood,
                           "\(speech) dB is inside the band and needs no change")
        }
    }

    func testTheBandEdgesMatchTheMeterExactly() {
        // The meter calls -18 "good" and -6 "loud". The calibration must agree,
        // or the word beside the meter and the calibration will contradict each
        // other on the same signal.
        XCTAssertEqual(evaluate(speech: -18).outcome, .alreadyGood)
        XCTAssertNotEqual(evaluate(speech: -18.5).outcome, .alreadyGood)
        XCTAssertNotEqual(evaluate(speech: -6).outcome, .alreadyGood)
    }

    // MARK: - Refusals

    func testSilenceIsReportedAsNothingHeard() {
        let r = evaluate(speech: -68, noise: -70)
        XCTAssertEqual(r.outcome, .nothingHeard)
        XCTAssertFalse(r.noisy, "there is nothing to advise about when nothing was said")
    }

    func testAQuietButRealVoiceIsNotMistakenForSilence() {
        // A distant microphone at low gain: genuinely quiet, and exactly the
        // case this feature exists for. It must not be refused.
        let r = evaluate(speech: -52, noise: -70, gain: 0)
        guard case .adjust = r.outcome else {
            return XCTFail("a quiet but audible voice must get an answer, got \(r.outcome)")
        }
    }

    func testAnOverloadedMicrophoneIsNotAGainProblem() {
        let r = evaluate(speech: -2, raw: -0.5, gain: 0)
        XCTAssertEqual(r.outcome, .tooLoud(atTheMicrophone: true))
    }

    func testOverloadIsCheckedBeforeTheBand() {
        // A microphone clipping its own converter while our gain happens to put
        // the result inside the band is still broken, and saying "already good"
        // would be the worst possible answer.
        let r = evaluate(speech: -12, raw: -0.2, gain: -12)
        XCTAssertEqual(r.outcome, .tooLoud(atTheMicrophone: true))
    }

    func testGainThatCannotComeDownFarEnoughAsksForThePad() {
        // Gain already at the bottom of its range and the voice still hot.
        let r = evaluate(speech: -2, raw: -30, gain: -20)
        XCTAssertEqual(r.outcome, .tooLoud(atTheMicrophone: false))
    }

    func testNotEnoughGainReportsTheBestItCanDo() {
        let r = evaluate(speech: -60, noise: -80, gain: 30)
        guard case let .notEnoughGain(best, resulting) = r.outcome else {
            return XCTFail("expected notEnoughGain, got \(r.outcome)")
        }
        XCTAssertEqual(best, 40, accuracy: 0.001, "the ceiling of the range")
        XCTAssertEqual(resulting, -50, accuracy: 0.001)
        XCTAssertLessThan(resulting, low, "still short of the band, which is why it refused")
    }

    // MARK: - The noise advisory

    func testAPoorRoomIsFlaggedWithoutChangingTheAnswer() {
        // A talker who is clearly audible in a room that is clearly too loud:
        // held level 7 dB over the room, peak 13 dB over it. The room is worth
        // saying out loud, but it does not change the gain arithmetic.
        let r = evaluate(speech: -27, sustained: -33, noise: -40, gain: 0)
        XCTAssertTrue(r.noisy)
        guard case let .adjust(newGain, _) = r.outcome else {
            return XCTFail("the gain answer must still be given, got \(r.outcome)")
        }
        XCTAssertEqual(newGain, 15, accuracy: 0.001)
    }

    func testAQuietRoomIsNotFlagged() {
        XCTAssertFalse(evaluate(speech: -27, noise: -70).noisy)
    }

    func testSignalToNoiseIsUnchangedByTheProposal() {
        // Gain lifts the voice and the room together, so the calibration cannot
        // improve this number and must not imply that it does.
        let quiet = evaluate(speech: -40, noise: -60, gain: 0)
        let loud  = evaluate(speech: -20, noise: -40, gain: 20)
        XCTAssertEqual(quiet.signalToNoiseDB, loud.signalToNoiseDB, accuracy: 0.001)
        XCTAssertEqual(quiet.noisy, loud.noisy)
    }

    // MARK: - Range handling

    func testTheProposalNeverLeavesTheUsableRange() {
        for speech in stride(from: Float(-90), through: Float(0), by: 3) {
            let r = evaluate(speech: speech, noise: -100, raw: -40, gain: 0)
            switch r.outcome {
            case let .adjust(newGain, _), let .notEnoughGain(newGain, _):
                XCTAssertGreaterThanOrEqual(newGain, range.lowerBound)
                XCTAssertLessThanOrEqual(newGain, range.upperBound)
            case .alreadyGood, .tooLoud, .nothingHeard:
                break
            }
        }
    }

    func testAWiderDeviceRangeIsUsed() {
        // Channels whose microphone has its own preamp get a taller ceiling.
        // The same measurement refuses against the default range and succeeds
        // against the wider one, which is the whole point of passing it in.
        guard case .notEnoughGain = evaluate(speech: -40, noise: -80, gain: 30).outcome else {
            return XCTFail("58 dB is beyond the default ceiling and should refuse")
        }
        let r = evaluate(speech: -40, noise: -80, gain: 30, range: -20...60)
        guard case let .adjust(newGain, resulting) = r.outcome else {
            return XCTFail("expected an adjustment, got \(r.outcome)")
        }
        XCTAssertEqual(newGain, 58, accuracy: 0.001)
        XCTAssertEqual(resulting, -12, accuracy: 0.001)
    }
}
