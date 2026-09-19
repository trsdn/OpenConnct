import XCTest
@testable import OpenConnctControl

final class LocalAPIStateTests: XCTestCase {
    func testEncodesTheDocumentedFieldNames() throws {
        let state = LocalAPIStateResponse(
            driverInstalled: true,
            engineRunning: true,
            channels: [
                LocalAPIChannelState(
                    index: 0, name: "Rode NT-USB", active: true,
                    muted: false, gainDB: 0.8, present: true)
            ])

        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["driverInstalled"] as? Bool, true)
        XCTAssertEqual(json["engineRunning"] as? Bool, true)
        let channels = try XCTUnwrap(json["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0]["index"] as? Int, 0)
        XCTAssertEqual(channels[0]["name"] as? String, "Rode NT-USB")
        XCTAssertEqual(channels[0]["active"] as? Bool, true)
        XCTAssertEqual(channels[0]["muted"] as? Bool, false)
        XCTAssertEqual(channels[0]["gainDB"] as? Double, 0.8)
        XCTAssertEqual(channels[0]["present"] as? Bool, true)
    }

    func testEncodesTheMixerFields() throws {
        let channel = LocalAPIChannelState(
            index: 1, name: "Boom", active: true, muted: false, gainDB: 3, present: true,
            soloed: true, faderDB: -6, highPass: "75", gate: true, compressor: false,
            exciter: false, bassEnhancer: true, pad: false)
        let data = try JSONEncoder().encode(channel)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["soloed"] as? Bool, true)
        XCTAssertEqual(json["faderDB"] as? Double, -6)
        XCTAssertEqual(json["highPass"] as? String, "75")
        XCTAssertEqual(json["gate"] as? Bool, true)
        XCTAssertEqual(json["compressor"] as? Bool, false)
        XCTAssertEqual(json["exciter"] as? Bool, false)
        XCTAssertEqual(json["bassEnhancer"] as? Bool, true)
        XCTAssertEqual(json["pad"] as? Bool, false)
    }
}
