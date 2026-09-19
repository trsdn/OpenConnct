import Foundation
import Security

/// The two small files a script reads to find and authenticate to the local
/// API: `api-port` and `api-token`, both in the Application Support directory.
///
/// The token is created once and kept, so a Stream Deck profile keeps working
/// across launches. It is readable by the owning user only (0600): that is the
/// whole trust boundary. Anything running as the same user could read the
/// mixer's own settings file too, so this adds no new exposure — what it
/// prevents is *other* software, and web pages, reaching the API without
/// having been given the token.
enum LocalAPICredentials {
    private static var portFile: URL { AppSupport.directory.appendingPathComponent("api-port") }
    private static var tokenFile: URL { AppSupport.directory.appendingPathComponent("api-token") }

    /// Reads the saved token, or creates one. 32 random bytes as hex.
    static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count == 64, existing.allSatisfy(\.isHexDigit) {
            restrictPermissions(tokenFile)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failed RNG must never fall through to a predictable token.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("SecRandomCopyBytes failed; refusing to create a guessable API token")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(
            atPath: tokenFile.path, contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600])
        restrictPermissions(tokenFile)
        return token
    }

    static func publish(port: UInt16) {
        try? Data("\(port)\n".utf8).write(to: portFile, options: .atomic)
    }

    /// Removed when the API stops, so a script finding no file knows the API is
    /// off rather than reading a stale port and being refused.
    static func retractPort() {
        try? FileManager.default.removeItem(at: portFile)
    }

    private static func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
