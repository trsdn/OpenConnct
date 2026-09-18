import Foundation

/// Body of `POST /v1/channel/{i}/mute`.
public struct LocalAPIMuteBody: Codable, Equatable {
    public let muted: Bool
    public init(muted: Bool) { self.muted = muted }
}

/// Body of `POST /v1/channel/{i}/gain`. See `LocalAPIChannelState.gainDB` for
/// why this is a decibel figure and not a normalized 0–1 value.
public struct LocalAPIGainBody: Codable, Equatable {
    public let gainDB: Float
    public init(gainDB: Float) { self.gainDB = gainDB }
}
