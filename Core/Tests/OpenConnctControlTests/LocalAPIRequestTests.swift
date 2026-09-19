import XCTest
@testable import OpenConnctControl

final class LocalAPIRequestTests: XCTestCase {
    func testParsesMethodAndPathFromRequestLine() {
        let raw = "GET /v1/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".data(using: .utf8)!
        let request = LocalAPIRequest.parse(raw)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/v1/state")
    }

    func testHeaderLookupIsCaseInsensitive() {
        let raw = "GET /v1/state HTTP/1.1\r\nAuthorization: Bearer abc123\r\n\r\n"
            .data(using: .utf8)!
        let request = LocalAPIRequest.parse(raw)
        XCTAssertEqual(request?.header(named: "authorization"), "Bearer abc123")
        XCTAssertEqual(request?.header(named: "AUTHORIZATION"), "Bearer abc123")
        XCTAssertEqual(request?.header(named: "Authorization"), "Bearer abc123")
    }

    func testExtractsBodyAfterTheBlankLine() {
        let raw = "POST /v1/channel/0/mute HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"muted\":true}"
            .data(using: .utf8)!
        let request = LocalAPIRequest.parse(raw)
        XCTAssertEqual(request?.body, "{\"muted\":true}".data(using: .utf8))
    }

    func testFramingWaitsForTheEndOfTheHead() {
        let partial = Data("GET /v1/state HTTP/1.1\r\nHost: x".utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: partial), .needMore)
    }

    func testFramingCompletesABodilessRequestAtTheBlankLine() {
        let raw = Data("GET /v1/state HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: raw), .complete(total: raw.count))
    }

    func testFramingWaitsForTheDeclaredBody() {
        let head = "POST /v1/channel/0/mute HTTP/1.1\r\nContent-Length: 14\r\n\r\n"
        XCTAssertEqual(LocalAPIRequest.framing(of: Data((head + "{\"mut").utf8)), .needMore)
        let full = Data((head + "{\"muted\":true}").utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: full), .complete(total: full.count))
    }

    func testFramingRejectsAnUnusableContentLength() {
        let raw = Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: raw), .invalid)
        let negative = Data("POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\n".utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: negative), .invalid)
    }

    func testFramingRefusesABodyLargerThanAnyRealRequest() {
        let raw = Data("POST /x HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        XCTAssertEqual(LocalAPIRequest.framing(of: raw), .invalid)
    }

    func testMalformedRequestLineFailsToParse() {
        let raw = "not an http request".data(using: .utf8)!
        XCTAssertNil(LocalAPIRequest.parse(raw))
    }
}
