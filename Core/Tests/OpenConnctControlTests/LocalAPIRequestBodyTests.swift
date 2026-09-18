import XCTest
@testable import OpenConnctControl

final class LocalAPIRequestBodyTests: XCTestCase {
    func testDecodesMuteBody() throws {
        let body = LocalAPIMuteBody(muted: true)
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(LocalAPIMuteBody.self, from: data)
        XCTAssertEqual(decoded.muted, true)
    }

    func testDecodesGainBody() throws {
        let data = "{\"gainDB\": -6.5}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LocalAPIGainBody.self, from: data)
        XCTAssertEqual(decoded.gainDB, -6.5)
    }
}
