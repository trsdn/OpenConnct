import XCTest

@testable import OpenConnctControl

final class ProcessingLocationTests: XCTestCase {

    private let range = HardwareGainRange(minDB: 0, maxDB: 40, stepDB: 1)

    func testGainRunsOnTheDeviceOnlyWhenThereIsOneAndItIsAllowed() {
        XCTAssertEqual(
            ChannelProcessingMap.resolve(hardwareGainRange: range, hardwareGainEnabled: true).gain,
            .device)
    }

    /// A microphone without a gain stage must not claim one.
    func testGainIsSoftwareWithoutADeviceStage() {
        XCTAssertEqual(
            ChannelProcessingMap.resolve(hardwareGainRange: nil, hardwareGainEnabled: true).gain,
            .software)
    }

    /// The badge has to follow the switch. If it kept saying "MIC" after the user
    /// turned the feature off, it would be telling them something untrue about
    /// where their signal is being amplified — which is the one thing a badge
    /// like this exists to get right.
    func testGainIsSoftwareWhenTheUserHasSwitchedTheDeviceStageOff() {
        XCTAssertEqual(
            ChannelProcessingMap.resolve(hardwareGainRange: range, hardwareGainEnabled: false).gain,
            .software)
    }

    /// Probing every device-level control CoreAudio publishes, across all scopes
    /// and elements, found gain, mute and direct monitoring — no pad and no
    /// high-pass. Until that changes these must not claim to be anything else.
    func testPadAndHighPassAreAlwaysSoftware() {
        for hasRange in [true, false] {
            for enabled in [true, false] {
                let map = ChannelProcessingMap.resolve(
                    hardwareGainRange: hasRange ? range : nil,
                    hardwareGainEnabled: enabled)
                XCTAssertEqual(map.pad, .software)
                XCTAssertEqual(map.highPass, .software)
            }
        }
    }

    func testBadgeTextIsShortEnoughToSitBesideAControl() {
        for location in [ProcessingLocation.device, .software] {
            XCTAssertLessThanOrEqual(location.badgeText.count, 4)
            XCTAssertFalse(location.badgeText.isEmpty)
        }
        XCTAssertNotEqual(ProcessingLocation.device.badgeText,
                          ProcessingLocation.software.badgeText)
    }
}

// MARK: - Body-switch note

/// The note exists because a microphone's own filter or pad button is invisible
/// to the host: there is no property to read, so the app cannot detect the
/// duplicate and can only warn. These tests pin the one thing that could quietly
/// rot — that the warning appears exactly when a duplicate is possible.
final class BodySwitchNoteTests: XCTestCase {

    func testNothingIsSaidWhenNeitherStageIsOn() {
        XCTAssertNil(ChannelProcessingMap.bodySwitchNote(padEnabled: false, highPassActive: false))
    }

    func testEachActiveStageIsNamedAndTheInactiveOneIsNot() {
        let filterOnly = ChannelProcessingMap.bodySwitchNote(padEnabled: false, highPassActive: true)
        XCTAssertNotNil(filterOnly)
        XCTAssertTrue(filterOnly!.contains("filter"))
        XCTAssertFalse(filterOnly!.contains("pad"),
                       "Warning about a pad the user has not switched on is noise.")

        let padOnly = ChannelProcessingMap.bodySwitchNote(padEnabled: true, highPassActive: false)
        XCTAssertNotNil(padOnly)
        XCTAssertTrue(padOnly!.contains("pad"))
        XCTAssertFalse(padOnly!.contains("filter"),
                       "Warning about a filter the user has not switched on is noise.")

        let both = ChannelProcessingMap.bodySwitchNote(padEnabled: true, highPassActive: true)
        XCTAssertNotNil(both)
        XCTAssertTrue(both!.contains("filter"))
        XCTAssertTrue(both!.contains("pad"))
    }

    /// The note must not assert that the microphone *has* such a switch — most do
    /// not, and the app cannot tell. Overstating it would train the user to
    /// ignore it.
    func testTheNoteIsHedgedRatherThanStated() {
        for (pad, hpf) in [(true, false), (false, true), (true, true)] {
            let note = ChannelProcessingMap.bodySwitchNote(padEnabled: pad, highPassActive: hpf)!
            XCTAssertTrue(note.hasPrefix("Some microphones"),
                          "The note claims a capability this app cannot verify: \(note)")
        }
    }

    /// It sits on a single fixed-height line in a card about 446pt wide, at 10pt.
    /// The limit is not a style preference: past it the text is truncated with an
    /// ellipsis and the warning loses its second half, which is the half that says
    /// what goes wrong. Measured on screen — 95 characters was already at the edge,
    /// and 101 was visibly cut.
    func testTheNoteFitsOnOneLine() {
        for (pad, hpf) in [(true, false), (false, true), (true, true)] {
            let note = ChannelProcessingMap.bodySwitchNote(padEnabled: pad, highPassActive: hpf)!
            XCTAssertLessThanOrEqual(note.count, 92, "Will be truncated on screen: \(note)")
        }
    }
}
