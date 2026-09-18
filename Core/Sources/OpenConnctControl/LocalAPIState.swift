import Foundation

/// One channel's status, as `GET /v1/state` reports it.
///
/// `gainDB` is deliberately named for its unit rather than left as a bare
/// `gain`: this API speaks the same decibel figure the app's own slider
/// shows, not a normalized 0–1 value, and a client reading `gainDB` cannot
/// mistake it for the other.
public struct LocalAPIChannelState: Codable, Equatable {
    public let index: Int
    public let name: String
    public let active: Bool
    public let muted: Bool
    public let gainDB: Float
    /// Whether the underlying USB microphone is currently plugged in. A
    /// Stream Deck button for a channel that has gone away should grey
    /// itself out rather than mute a device that is no longer there.
    public let present: Bool

    public init(index: Int, name: String, active: Bool, muted: Bool, gainDB: Float, present: Bool) {
        self.index = index
        self.name = name
        self.active = active
        self.muted = muted
        self.gainDB = gainDB
        self.present = present
    }
}

/// The full body of `GET /v1/state`.
public struct LocalAPIStateResponse: Codable, Equatable {
    public let driverInstalled: Bool
    public let engineRunning: Bool
    public let channels: [LocalAPIChannelState]

    public init(driverInstalled: Bool, engineRunning: Bool, channels: [LocalAPIChannelState]) {
        self.driverInstalled = driverInstalled
        self.engineRunning = engineRunning
        self.channels = channels
    }
}
