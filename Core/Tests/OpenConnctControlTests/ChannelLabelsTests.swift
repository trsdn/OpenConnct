import XCTest
@testable import OpenConnctControl

/// Names as they arrive from the system, shortened to fit a 64 pt strip.
///
/// Real device names are used as fixtures, with the manufacturer replaced, so
/// the shapes are the ones that actually turn up: a shared manufacturer word, a
/// localised generic name that shares nothing, and single-word names.
final class ChannelLabelsTests: XCTestCase {

    func testOneChannelIsLeftAlone() {
        // Nothing to be told apart from, so nothing is noise.
        XCTAssertEqual(ChannelLabels.shorten(["Acme NT-USB Mini"]), ["Acme NT-USB Mini"])
    }

    func testDropsAManufacturerSharedByTwoOfThree() {
        // The case from the report: two devices from one maker, one generic
        // name from the system that shares nothing with them.
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme NT-USB Mini", "Acme VideoMic NTG", "Externes Mikrofon"]),
            ["NT-USB Mini", "VideoMic NTG", "Externes Mikrofon"])
    }

    func testDropsAWordSharedByEveryChannel() {
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme One", "Acme Two"]),
            ["One", "Two"])
    }

    func testDropsSeveralSharedWordsInTurn() {
        // Dropping a word exposes the next one, which may also be shared.
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme Pro One", "Acme Pro Two"]),
            ["One", "Two"])
    }

    func testKeepsAWordThatOnlyOneChannelHas() {
        // "Pro" is shared by two, "Lite" by nobody, so "Lite" stays.
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme Pro One", "Acme Pro Two", "Acme Lite Three"]),
            ["One", "Two", "Lite Three"])
    }

    func testKeepsNamesThatShareNothing() {
        XCTAssertEqual(
            ChannelLabels.shorten(["Studio One", "Field Two"]),
            ["Studio One", "Field Two"])
    }

    func testNeverReducesANameToNothing() {
        // "Acme" is shared, but it is all the first name has.
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme", "Acme One"]),
            ["Acme", "One"])
    }

    func testSingleWordNamesSurviveEvenWhenIdentical() {
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme", "Acme"]),
            ["Acme", "Acme"])
    }

    func testTwoOfTheSameModelStayIdentical() {
        // They were identical before, so nothing the mixer had is lost. The
        // channels are told apart by their UID, not by this string.
        XCTAssertEqual(
            ChannelLabels.shorten(["Acme One", "Acme One"]),
            ["One", "One"])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            ChannelLabels.shorten(["ACME One", "acme Two"]),
            ["One", "Two"])
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            ChannelLabels.shorten(["  Acme One ", "Acme Two"]),
            ["One", "Two"])
    }

    func testABlankNameSurvivesAsItself() {
        // Nothing to shorten and nothing to crash on.
        XCTAssertEqual(
            ChannelLabels.shorten(["   ", "Acme One"]),
            ["", "Acme One"])
    }

    func testResultAlwaysMatchesTheInputCount() {
        // Callers zip this back against their channels, so the count is a
        // contract, not an accident.
        let names = ["Acme One", "Acme Two", "Acme", "Other", "  "]
        XCTAssertEqual(ChannelLabels.shorten(names).count, names.count)
    }

    func testEmptyListIsEmpty() {
        XCTAssertEqual(ChannelLabels.shorten([]), [])
    }
}
