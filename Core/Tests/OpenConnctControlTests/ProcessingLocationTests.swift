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
