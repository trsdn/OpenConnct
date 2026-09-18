import XCTest
@testable import OpenConnctControl

final class LocalAPIAuthTests: XCTestCase {
    private func request(authorization: String? = nil, origin: String? = nil) -> LocalAPIRequest {
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        if let origin { headers["Origin"] = origin }
        return LocalAPIRequest(method: "GET", path: "/v1/state", headers: headers, body: Data())
    }

    func testRejectsRequestWithNoAuthorizationHeader() {
        XCTAssertFalse(LocalAPIAuth.isAuthorized(request(), expectedToken: "secret"))
    }

    func testRejectsWrongToken() {
        let req = request(authorization: "Bearer wrong")
        XCTAssertFalse(LocalAPIAuth.isAuthorized(req, expectedToken: "secret"))
    }

    func testAcceptsCorrectBearerToken() {
        let req = request(authorization: "Bearer secret")
        XCTAssertTrue(LocalAPIAuth.isAuthorized(req, expectedToken: "secret"))
    }

    func testRejectsRequestThatCarriesAnOriginHeaderEvenWithTheCorrectToken() {
        let req = request(authorization: "Bearer secret", origin: "https://example.com")
        XCTAssertFalse(LocalAPIAuth.isAuthorized(req, expectedToken: "secret"))
    }
}
