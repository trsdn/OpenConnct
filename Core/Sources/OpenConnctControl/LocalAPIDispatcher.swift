import Foundation

/// A finished HTTP response, ready to be written to the socket.
public struct LocalAPIResponse: Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    static func error(_ status: Int, _ message: String) -> LocalAPIResponse {
        let payload = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return LocalAPIResponse(status: status, body: payload)
    }

    private var reason: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    /// One response per connection: `Connection: close`, so no framing beyond
    /// `Content-Length` is ever needed and no client can hold a socket open.
    public func serialized() -> Data {
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// What the API is allowed to do to the app. The dispatcher knows nothing
/// about audio; the app's parameter store conforms to this, so the API can
/// only ever reach the mixer through the same door the interface uses.
@MainActor
public protocol LocalAPIBackend: AnyObject {
    func apiState() -> LocalAPIStateResponse
    /// `false` when there is no such channel.
    func apiSetMuted(channel: Int, muted: Bool) -> Bool
    func apiToggleMute(channel: Int) -> Bool
    func apiSetGainDB(channel: Int, gainDB: Float) -> Bool
    func apiSetSoloed(channel: Int, soloed: Bool) -> Bool
    func apiToggleSolo(channel: Int) -> Bool
    func apiSetFaderDB(channel: Int, faderDB: Float) -> Bool
    func apiToggleEffect(channel: Int, effect: LocalAPIEffect) -> Bool
    func apiStartEngine()
    func apiStopEngine()
}

/// Authenticate, route, act, answer. Pure apart from the calls on `backend`.
public enum LocalAPIDispatcher {
    @MainActor
    public static func handle(
        _ request: LocalAPIRequest, token: String, backend: LocalAPIBackend
    ) -> LocalAPIResponse {
        // Authentication first, so an unauthenticated caller learns nothing —
        // not even which paths exist.
        guard LocalAPIAuth.isAuthorized(request, expectedToken: token) else {
            return .error(401, "unauthorized")
        }
        guard let route = LocalAPIRoute.match(method: request.method, path: request.path) else {
            return .error(404, "not found")
        }

        switch route {
        case .state:
            break
        case .setMute(let channel):
            guard let body = try? JSONDecoder().decode(LocalAPIMuteBody.self, from: request.body) else {
                return .error(400, "expected {\"muted\": true|false}")
            }
            guard backend.apiSetMuted(channel: channel, muted: body.muted) else {
                return .error(404, "no such channel")
            }
        case .toggleMute(let channel):
            guard backend.apiToggleMute(channel: channel) else { return .error(404, "no such channel") }
        case .setGain(let channel):
            guard let body = try? JSONDecoder().decode(LocalAPIGainBody.self, from: request.body),
                  body.gainDB.isFinite
            else { return .error(400, "expected {\"gainDB\": <number>}") }
            guard backend.apiSetGainDB(channel: channel, gainDB: body.gainDB) else {
                return .error(404, "no such channel")
            }
        case .setSolo(let channel):
            guard let body = try? JSONDecoder().decode(LocalAPISoloBody.self, from: request.body) else {
                return .error(400, "expected {\"soloed\": true|false}")
            }
            guard backend.apiSetSoloed(channel: channel, soloed: body.soloed) else {
                return .error(404, "no such channel")
            }
        case .toggleSolo(let channel):
            guard backend.apiToggleSolo(channel: channel) else { return .error(404, "no such channel") }
        case .setFader(let channel):
            guard let body = try? JSONDecoder().decode(LocalAPIFaderBody.self, from: request.body),
                  body.faderDB.isFinite
            else { return .error(400, "expected {\"faderDB\": <number>}") }
            guard backend.apiSetFaderDB(channel: channel, faderDB: body.faderDB) else {
                return .error(404, "no such channel")
            }
        case .toggleEffect(let channel, let effect):
            guard backend.apiToggleEffect(channel: channel, effect: effect) else {
                return .error(404, "no such channel")
            }
        case .startEngine:
            backend.apiStartEngine()
        case .stopEngine:
            backend.apiStopEngine()
        }

        // Every successful call answers with the resulting state, so a client
        // never needs a second round trip to learn what its own request did.
        guard let body = try? JSONEncoder().encode(backend.apiState()) else {
            return .error(400, "unencodable state")
        }
        return LocalAPIResponse(status: 200, body: body)
    }
}
