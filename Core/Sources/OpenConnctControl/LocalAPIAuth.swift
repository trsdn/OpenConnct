import Foundation

/// The two checks that stand between a request on `127.0.0.1` and the
/// mixer: it must carry the right bearer token, and it must not carry an
/// `Origin` header at all.
///
/// `Origin` is what tells the two kinds of caller this API can ever see
/// apart. A script or a Stream Deck plugin never sends it; a browser always
/// does, on every request, including ones a malicious page issues to
/// `127.0.0.1` by DNS rebinding hoping something is listening. Rejecting its
/// mere presence — not checking its value — is what closes that door,
/// because a page can set `Origin` to anything it likes but cannot omit it.
public enum LocalAPIAuth {
    public static func isAuthorized(_ request: LocalAPIRequest, expectedToken: String) -> Bool {
        guard request.header(named: "Origin") == nil else { return false }
        guard let authorization = request.header(named: "Authorization") else { return false }
        return authorization == "Bearer \(expectedToken)"
    }
}
