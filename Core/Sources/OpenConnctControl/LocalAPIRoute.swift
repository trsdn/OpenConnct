import Foundation

/// The closed set of endpoints this API answers (issue #8). Not a general
/// router: the paths are fixed and few, so matching them is a fixed set of
/// comparisons rather than a pattern language nothing else here would ever
/// need.
public enum LocalAPIRoute: Equatable {
    case state
    case setMute(channel: Int)
    case toggleMute(channel: Int)
    case setGain(channel: Int)
    case startEngine
    case stopEngine

    /// `nil` for anything unrecognised — an unknown method, an unknown path,
    /// or a channel segment that is not a plain non-negative integer. The
    /// caller answers `404` (or `405`) rather than guessing at intent.
    public static func match(method: String, path: String) -> LocalAPIRoute? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if method == "GET", segments == ["v1", "state"] {
            return .state
        }
        if method == "POST", segments == ["v1", "engine", "start"] {
            return .startEngine
        }
        if method == "POST", segments == ["v1", "engine", "stop"] {
            return .stopEngine
        }
        guard method == "POST", segments.count >= 3,
              segments[0] == "v1", segments[1] == "channel",
              let channel = Int(segments[2]), channel >= 0
        else { return nil }

        switch Array(segments[3...]) {
        case ["mute"]: return .setMute(channel: channel)
        case ["mute", "toggle"]: return .toggleMute(channel: channel)
        case ["gain"]: return .setGain(channel: channel)
        default: return nil
        }
    }
}
