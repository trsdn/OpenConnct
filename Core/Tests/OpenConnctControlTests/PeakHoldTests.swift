import XCTest
@testable import OpenConnctControl

/// The hold behind the meter's thin mark and the word beside it.
final class PeakHoldTests: XCTestCase {

    func testStartsAtTheFloor() {
        XCTAssertEqual(PeakHold().db, -120)
        XCTAssertEqual(PeakHold(floorDB: -60).db, -60)
    }

    func testRisesInstantly() {
        // A peak that is missed is a peak that is useless.
        var h = PeakHold()
        h.advance(to: -12, dt: 0.05)
        XCTAssertEqual(h.db, -12)
    }

    func testHoldsStillForTheHoldTime() {
        var h = PeakHold(holdSeconds: 1.5, fallDBPerSecond: 12)
        h.advance(to: -12, dt: 0.05)
        for _ in 0..<28 { h.advance(to: -40, dt: 0.05) }  // 1.4 s
        XCTAssertEqual(h.db, -12, "should not have started falling yet")
    }

    func testFallsAtTheStatedRateAfterTheHold() {
        var h = PeakHold(holdSeconds: 1.0, fallDBPerSecond: 12)
        h.advance(to: -12, dt: 0.05)
        // 1.0 s of hold, then 0.5 s of fall = 6 dB.
        for _ in 0..<30 { h.advance(to: -60, dt: 0.05) }
        XCTAssertEqual(h.db, -18, accuracy: 0.3)
    }

    func testNeverFallsBelowTheCurrentReading() {
        // A mark underneath the bar would be hidden by it, and would claim a
        // level lower than the one being drawn.
        var h = PeakHold(holdSeconds: 0, fallDBPerSecond: 100)
        h.advance(to: -6, dt: 0.05)
        h.advance(to: -20, dt: 1.0)
        XCTAssertEqual(h.db, -20)
    }

    func testARisingSignalReArmsTheHold() {
        var h = PeakHold(holdSeconds: 1.0, fallDBPerSecond: 12)
        h.advance(to: -30, dt: 0.05)
        for _ in 0..<10 { h.advance(to: -40, dt: 0.05) }  // 0.5 s into the hold
        h.advance(to: -10, dt: 0.05)                      // louder: re-arms
        for _ in 0..<18 { h.advance(to: -40, dt: 0.05) }  // 0.9 s, still holding
        XCTAssertEqual(h.db, -10)
    }

    func testSpeechPausesDoNotMoveIt() {
        // The case this exists for: a voice peaking at -12 with a 0.4 s gap
        // between sentences. The meter's own fall is ~29 dB/s, so the raw peak
        // reads about -24 in that gap and the word beside it would say "quiet".
        var h = PeakHold()
        var raw: Float = -12
        h.advance(to: raw, dt: 0.05)
        for _ in 0..<8 {                       // 0.4 s of silence
            raw -= 29.0 * 0.05
            h.advance(to: raw, dt: 0.05)
        }
        XCTAssertEqual(h.db, -12, "the hold must ride straight through a pause")
        XCTAssertLessThan(raw, -20, "…while the raw peak really has fallen")
    }

    func testALargeTimeStepIsTheCallersToClamp() {
        // Documents the contract rather than defending against it: the hold
        // applies whatever dt it is given, so callers clamp for stalls.
        var h = PeakHold(holdSeconds: 0, fallDBPerSecond: 12)
        h.advance(to: -6, dt: 0.05)
        h.advance(to: -120, dt: 10)
        XCTAssertEqual(h.db, -120)
    }

    func testNegativeTimeIsIgnoredRatherThanRunningBackwards() {
        var h = PeakHold(holdSeconds: 0, fallDBPerSecond: 12)
        h.advance(to: -6, dt: 0.05)
        h.advance(to: -60, dt: -5)
        XCTAssertEqual(h.db, -6, accuracy: 0.001)
    }

    func testResetReturnsToTheFloor() {
        var h = PeakHold(floorDB: -120)
        h.advance(to: -3, dt: 0.05)
        h.reset()
        XCTAssertEqual(h.db, -120)
        // And the hold window is cleared too, so the next quiet reading falls.
        h.advance(to: -50, dt: 0.05)
        XCTAssertEqual(h.db, -50)
    }
}
