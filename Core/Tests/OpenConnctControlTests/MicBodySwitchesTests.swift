import XCTest
@testable import OpenConnctControl

/// The switch positions a microphone reports about itself, and the one thing
/// the app does with them: stop a stage being applied twice without saying so.
final class MicBodySwitchesTests: XCTestCase {

    func testStartsWithEverythingOff() {
        let s = MicBodySwitches()
        XCTAssertFalse(s.padEnabled)
        XCTAssertNil(s.highPassHz)
        XCTAssertFalse(s.highBoostEnabled)
        XCTAssertFalse(s.safetyChannelEnabled)
    }

    func testAppliesEachSwitchIndependently() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        s.apply(.highBoost, value: 1)
        XCTAssertTrue(s.padEnabled)
        XCTAssertTrue(s.highBoostEnabled)
        XCTAssertFalse(s.safetyChannelEnabled)
        XCTAssertNil(s.highPassHz)
    }

    /// The filter is the only three-valued switch on the device, and its two
    /// frequencies are the two the app also offers — which is the whole reason
    /// any of this is read.
    func testFilterFrequencies() {
        var s = MicBodySwitches()
        s.apply(.highPass, value: 0)
        XCTAssertNil(s.highPassHz)
        s.apply(.highPass, value: 1)
        XCTAssertEqual(s.highPassHz, 75)
        s.apply(.highPass, value: 2)
        XCTAssertEqual(s.highPassHz, 150)
    }

    /// A value this app does not recognise must not be reported as a frequency
    /// it does recognise. Off is the honest reading.
    func testUnknownFilterValueIsTreatedAsOff() {
        var s = MicBodySwitches()
        s.apply(.highPass, value: 9)
        XCTAssertNil(s.highPassHz)
    }

    func testSwitchesTurnBackOff() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        s.apply(.pad, value: 0)
        XCTAssertFalse(s.padEnabled)
    }

    /// The four-step press cycle printed in the device's instructions: pad on,
    /// then pad off with safety on, then both, then neither. This exact
    /// sequence across these two properties is what established the mapping, so
    /// it is worth keeping as a test rather than only as a note.
    func testThePressCycleThatIdentifiedPadAndSafety() {
        var s = MicBodySwitches()
        let cycle: [(pad: UInt8, safety: UInt8)] = [(1, 0), (0, 1), (1, 1), (0, 0)]
        var seen: [(Bool, Bool)] = []
        for step in cycle {
            s.apply(.pad, value: step.pad)
            s.apply(.safetyChannel, value: step.safety)
            seen.append((s.padEnabled, s.safetyChannelEnabled))
        }
        XCTAssertEqual(seen.map(\.0), [true, false, true, false])
        XCTAssertEqual(seen.map(\.1), [false, true, true, false])
    }

    // MARK: - Double application

    func testDetectsTheSameFilterInBothPlaces() {
        var s = MicBodySwitches()
        s.apply(.highPass, value: 1)
        XCTAssertTrue(s.duplicatesHighPass(appHighPassHz: 75))
        XCTAssertFalse(s.duplicatesHighPass(appHighPassHz: 150))
        XCTAssertFalse(s.duplicatesHighPass(appHighPassHz: nil))
    }

    func testNoFilterOnTheDeviceIsNeverADuplicate() {
        let s = MicBodySwitches()
        XCTAssertFalse(s.duplicatesHighPass(appHighPassHz: 75))
    }

    func testDetectsPadInBothPlaces() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        XCTAssertTrue(s.duplicatesPad(appPadEnabled: true))
        XCTAssertFalse(s.duplicatesPad(appPadEnabled: false))
        XCTAssertFalse(MicBodySwitches().duplicatesPad(appPadEnabled: true))
    }

    // MARK: - What the user is told

    /// The improvement this whole exercise bought: when the microphone can be
    /// asked and says its switches are off, the app says nothing at all.
    func testKnownAndClearSaysNothing() {
        let s = MicBodySwitches()
        XCTAssertNil(ChannelProcessingMap.bodySwitchNote(
            padEnabled: true, highPassActive: true, reported: s))
    }

    func testKnownAndStackedNamesTheFrequency() {
        var s = MicBodySwitches()
        s.apply(.highPass, value: 2)
        let note = ChannelProcessingMap.bodySwitchNote(
            padEnabled: false, highPassActive: true, reported: s)
        XCTAssertEqual(note, "Your microphone is also filtering at 150 Hz. Both apply.")
    }

    func testKnownAndStackedPad() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        let note = ChannelProcessingMap.bodySwitchNote(
            padEnabled: true, highPassActive: false, reported: s)
        XCTAssertEqual(note, "Your microphone's own pad is on. Both apply.")
    }

    func testKnownAndBothStacked() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        s.apply(.highPass, value: 1)
        let note = ChannelProcessingMap.bodySwitchNote(
            padEnabled: true, highPassActive: true, reported: s)
        XCTAssertEqual(
            note, "Your microphone's own pad is on and it is filtering at 75 Hz. Both apply.")
    }

    /// Two *different* cut frequencies still remove more than intended, so this
    /// warns even though it is not a duplicate in the strict sense.
    func testDifferentFrequenciesStillWarn() {
        var s = MicBodySwitches()
        s.apply(.highPass, value: 1)
        XCTAssertNotNil(ChannelProcessingMap.bodySwitchNote(
            padEnabled: false, highPassActive: true, reported: s))
    }

    /// A stage the user has not switched on cannot be applied twice, whatever
    /// the microphone is doing.
    func testAStageThatIsOffIsNeverWarnedAbout() {
        var s = MicBodySwitches()
        s.apply(.pad, value: 1)
        s.apply(.highPass, value: 1)
        XCTAssertNil(ChannelProcessingMap.bodySwitchNote(
            padEnabled: false, highPassActive: false, reported: s))
    }

    /// Most microphones cannot be asked, and their behaviour must not change.
    func testUnknownKeepsTheOldHedgedWording() {
        XCTAssertNil(ChannelProcessingMap.bodySwitchNote(
            padEnabled: false, highPassActive: false, reported: nil))
        XCTAssertEqual(
            ChannelProcessingMap.bodySwitchNote(
                padEnabled: true, highPassActive: false, reported: nil),
            "Some microphones have their own pad switch on the body. "
                + "If yours is set, both apply.")
        XCTAssertNotNil(ChannelProcessingMap.bodySwitchNote(
            padEnabled: true, highPassActive: true, reported: nil))
    }

    /// Omitting the argument entirely must behave as "cannot be asked", because
    /// every existing caller does exactly that.
    func testDefaultIsUnknown() {
        XCTAssertEqual(
            ChannelProcessingMap.bodySwitchNote(padEnabled: true, highPassActive: false),
            ChannelProcessingMap.bodySwitchNote(
                padEnabled: true, highPassActive: false, reported: nil))
    }
}
