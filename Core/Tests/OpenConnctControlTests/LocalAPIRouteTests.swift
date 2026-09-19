import XCTest
@testable import OpenConnctControl

final class LocalAPIRouteTests: XCTestCase {
    func testMatchesGetState() {
        XCTAssertEqual(LocalAPIRoute.match(method: "GET", path: "/v1/state"), .state)
    }

    func testMatchesChannelMute() {
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", path: "/v1/channel/2/mute"),
            .setMute(channel: 2))
    }

    func testMatchesChannelMuteToggle() {
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", path: "/v1/channel/0/mute/toggle"),
            .toggleMute(channel: 0))
    }

    func testMatchesChannelGain() {
        XCTAssertEqual(
            LocalAPIRoute.match(method: "POST", path: "/v1/channel/1/gain"),
            .setGain(channel: 1))
    }

    func testMatchesEngineStartAndStop() {
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", path: "/v1/engine/start"), .startEngine)
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", path: "/v1/engine/stop"), .stopEngine)
    }

    func testRejectsNonNumericChannelIndex() {
        XCTAssertNil(LocalAPIRoute.match(method: "POST", path: "/v1/channel/abc/mute"))
    }

    func testRejectsNegativeChannelIndex() {
        XCTAssertNil(LocalAPIRoute.match(method: "POST", path: "/v1/channel/-1/mute"))
    }

    func testRejectsUnknownPath() {
        XCTAssertNil(LocalAPIRoute.match(method: "GET", path: "/v1/nonsense"))
    }

    func testRejectsRightPathWrongMethod() {
        XCTAssertNil(LocalAPIRoute.match(method: "POST", path: "/v1/state"))
    }

    func testMatchesSolo() {
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", path: "/v1/channel/1/solo"), .setSolo(channel: 1))
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", path: "/v1/channel/1/solo/toggle"), .toggleSolo(channel: 1))
    }

    func testMatchesFader() {
        XCTAssertEqual(LocalAPIRoute.match(method: "POST", path: "/v1/channel/2/fader"), .setFader(channel: 2))
    }

    func testMatchesEveryEffectToggle() {
        let expected: [(String, LocalAPIEffect)] = [
            ("highpass", .highPass), ("gate", .gate), ("compressor", .compressor),
            ("exciter", .exciter), ("bass", .bassEnhancer), ("pad", .pad),
        ]
        for (name, effect) in expected {
            XCTAssertEqual(
                LocalAPIRoute.match(method: "POST", path: "/v1/channel/0/effect/\(name)/toggle"),
                .toggleEffect(channel: 0, effect: effect), name)
        }
    }

    func testRejectsAnEffectThatDoesNotExist() {
        XCTAssertNil(LocalAPIRoute.match(method: "POST", path: "/v1/channel/0/effect/reverb/toggle"))
    }

    func testEffectToggleNeedsPost() {
        XCTAssertNil(LocalAPIRoute.match(method: "GET", path: "/v1/channel/0/effect/gate/toggle"))
    }
}
