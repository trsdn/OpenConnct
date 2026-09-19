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

/// Body of `POST /v1/channel/{i}/solo`.
public struct LocalAPISoloBody: Codable, Equatable {
    public let soloed: Bool
    public init(soloed: Bool) { self.soloed = soloed }
}

/// Body of `POST /v1/channel/{i}/fader`: the channel's level in the mix, in
/// decibels, not the microphone's input gain.
public struct LocalAPIFaderBody: Codable, Equatable {
    public let faderDB: Float
    public init(faderDB: Float) { self.faderDB = faderDB }
}
