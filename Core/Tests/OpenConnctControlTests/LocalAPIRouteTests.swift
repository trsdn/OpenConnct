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
}
