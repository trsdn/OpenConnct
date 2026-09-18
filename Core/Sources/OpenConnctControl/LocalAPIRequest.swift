import Foundation

/// A parsed HTTP/1.1 request, for the loopback-only control API (issue #8).
///
/// Deliberately minimal: this API has exactly one client shape (a script or a
/// Stream Deck plugin on the same machine), not a browser and not a
/// general-purpose HTTP client, so it does not chase the parts of the spec
/// nothing here will ever send — chunked transfer encoding, continuation
/// lines, multiple values for one header. A request outside what this
/// understands parses to `nil` and the connection is closed, rather than
/// guessed at.
public struct LocalAPIRequest: Equatable {
    public let method: String
    public let path: String
    /// Keyed by lowercased header name — see `header(named:)`, the only
    /// intended way to read one, since HTTP header names are case-insensitive.
    private let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = Dictionary(
            headers.map { (key, value) in (key.lowercased(), value) },
            uniquingKeysWith: { first, _ in first })
        self.body = body
    }

    /// Looks up a header by name, ignoring case, as HTTP requires.
    public func header(named name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Parses a full request from raw bytes already read off the socket.
    ///
    /// `nil` for anything that does not look like a well-formed HTTP/1.1
    /// request line — the caller's job is to close the connection, not to
    /// guess what a malformed client meant.
    public static func parse(_ data: Data) -> LocalAPIRequest? {
        // The blank line is the one required piece of structure: everything
        // before it is header text, addressable as UTF-8; everything after it
        // is the body, which is arbitrary bytes and must not be forced through
        // the same String round-trip.
        let separator = "\r\n\r\n".data(using: .utf8)!
        guard let separatorRange = data.range(of: separator) else { return nil }
        let head = data.subdata(in: data.startIndex..<separatorRange.lowerBound)
        let body = data.subdata(in: separatorRange.upperBound..<data.endIndex)

        guard let headText = String(data: head, encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return LocalAPIRequest(method: method, path: path, headers: headers, body: body)
    }
}
