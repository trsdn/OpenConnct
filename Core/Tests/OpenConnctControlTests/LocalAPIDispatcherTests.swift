import XCTest
@testable import OpenConnctControl

@MainActor
private final class FakeBackend: LocalAPIBackend {
    var channels: [LocalAPIChannelState] = [
        LocalAPIChannelState(index: 0, name: "Mic A", active: true, muted: false, gainDB: 3, present: true),
        LocalAPIChannelState(index: 1, name: "Mic B", active: false, muted: true, gainDB: 0, present: false),
    ]
    var engineRunning = true
    private(set) var calls: [String] = []

    func apiState() -> LocalAPIStateResponse {
        LocalAPIStateResponse(driverInstalled: true, engineRunning: engineRunning, channels: channels)
    }
    func apiSetMuted(channel: Int, muted: Bool) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("mute \(channel) \(muted)")
        let c = channels[channel]
        channels[channel] = LocalAPIChannelState(
            index: c.index, name: c.name, active: c.active, muted: muted, gainDB: c.gainDB, present: c.present)
        return true
    }
    func apiToggleMute(channel: Int) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        return apiSetMuted(channel: channel, muted: !channels[channel].muted)
    }
    func apiSetGainDB(channel: Int, gainDB: Float) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("gain \(channel) \(gainDB)")
        return true
    }
    func apiSetSoloed(channel: Int, soloed: Bool) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("solo \(channel) \(soloed)"); return true
    }
    func apiToggleSolo(channel: Int) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("solo-toggle \(channel)"); return true
    }
    func apiSetFaderDB(channel: Int, faderDB: Float) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("fader \(channel) \(faderDB)"); return true
    }
    func apiToggleEffect(channel: Int, effect: LocalAPIEffect) -> Bool {
        guard channels.indices.contains(channel) else { return false }
        calls.append("effect \(channel) \(effect.rawValue)"); return true
    }
    func apiStartEngine() { calls.append("start"); engineRunning = true }
    func apiStopEngine() { calls.append("stop"); engineRunning = false }
}

@MainActor
final class LocalAPIDispatcherTests: XCTestCase {
    private let token = "secret"

    private func request(
        _ method: String, _ path: String, body: String = "",
        authorization: String? = "Bearer secret", origin: String? = nil
    ) -> LocalAPIRequest {
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        if let origin { headers["Origin"] = origin }
        return LocalAPIRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    private func json(_ response: LocalAPIResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testUnauthenticatedRequestGets401BeforeAnyRouting() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("GET", "/v1/nonsense", authorization: nil), token: token, backend: backend)
        XCTAssertEqual(r.status, 401)
    }

    func testBrowserRequestWithOriginGets401EvenWithTheRightToken() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("GET", "/v1/state", origin: "https://evil.example"), token: token, backend: backend)
        XCTAssertEqual(r.status, 401)
    }

    func testUnknownRouteGets404() {
        let r = LocalAPIDispatcher.handle(request("GET", "/v1/nonsense"), token: token, backend: FakeBackend())
        XCTAssertEqual(r.status, 404)
    }

    func testStateReturnsTheBackendSnapshot() throws {
        let r = LocalAPIDispatcher.handle(request("GET", "/v1/state"), token: token, backend: FakeBackend())
        XCTAssertEqual(r.status, 200)
        let body = try json(r)
        XCTAssertEqual(body["engineRunning"] as? Bool, true)
        XCTAssertEqual((body["channels"] as? [Any])?.count, 2)
    }

    func testMuteAppliesAndReturnsTheNewState() throws {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/mute", body: "{\"muted\":true}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["mute 0 true"])
        let channels = try XCTUnwrap(try json(r)["channels"] as? [[String: Any]])
        XCTAssertEqual(channels[0]["muted"] as? Bool, true)
    }

    func testMuteWithMalformedBodyGets400AndChangesNothing() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/mute", body: "not json"), token: token, backend: backend)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testMuteOnAChannelThatDoesNotExistGets404() {
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/9/mute", body: "{\"muted\":true}"), token: token, backend: FakeBackend())
        XCTAssertEqual(r.status, 404)
    }

    func testToggleFlipsTheCurrentState() throws {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/1/mute/toggle"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["mute 1 false"])
    }

    func testGainIsPassedThroughInDecibels() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/gain", body: "{\"gainDB\":-6.5}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["gain 0 -6.5"])
    }

    func testGainThatIsNotAFiniteNumberIsRejected() {
        let backend = FakeBackend()
        // JSON has no NaN literal, but 1e999 decodes to +infinity for Float.
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/gain", body: "{\"gainDB\":1e999}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testEngineStartAndStop() {
        let backend = FakeBackend()
        XCTAssertEqual(LocalAPIDispatcher.handle(request("POST", "/v1/engine/stop"), token: token, backend: backend).status, 200)
        XCTAssertEqual(LocalAPIDispatcher.handle(request("POST", "/v1/engine/start"), token: token, backend: backend).status, 200)
        XCTAssertEqual(backend.calls, ["stop", "start"])
    }

    func testResponseSerializesAsHTTP11WithLengthAndClose() throws {
        let r = LocalAPIResponse(status: 404, body: Data("{\"error\":\"x\"}".utf8))
        let text = try XCTUnwrap(String(data: r.serialized(), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 13\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"error\":\"x\"}"))
    }

    func testSoloIsPassedThroughAndAnswersWithTheState() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/1/solo", body: "{\"soloed\":true}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["solo 1 true"])
    }

    func testSoloWithAMalformedBodyChangesNothing() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/1/solo", body: "{}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testSoloToggle() {
        let backend = FakeBackend()
        XCTAssertEqual(LocalAPIDispatcher.handle(request("POST", "/v1/channel/0/solo/toggle"), token: token, backend: backend).status, 200)
        XCTAssertEqual(backend.calls, ["solo-toggle 0"])
    }

    func testFaderIsPassedThroughInDecibels() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/fader", body: "{\"faderDB\":-12.5}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["fader 0 -12.5"])
    }

    func testFaderThatIsNotAFiniteNumberIsRejected() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/0/fader", body: "{\"faderDB\":1e999}"), token: token, backend: backend)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testEffectToggleReachesTheBackendWithTheEffect() {
        let backend = FakeBackend()
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/1/effect/highpass/toggle"), token: token, backend: backend)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.calls, ["effect 1 highpass"])
    }

    func testEffectToggleOnAChannelThatDoesNotExistGets404() {
        let r = LocalAPIDispatcher.handle(
            request("POST", "/v1/channel/9/effect/gate/toggle"), token: token, backend: FakeBackend())
        XCTAssertEqual(r.status, 404)
    }
}
