import Foundation

// Meters and diagnostics change 30 times a second while audio is flowing.
// Publishing them from `ParameterStore` meant every view that observed the
// store — the mixer, every channel strip, the detail pane, every effect panel
// and every slider — was invalidated on each tick, because SwiftUI's dependency
// is on the *object*, not on the individual property that changed. Measured
// cost with two microphones live: ~26% of a core, essentially all of it inside
// AttributeGraph and SwiftUICore, while the audio threads together used 0.36%.
//
// So the fast-changing values live here instead, in one small observable object
// per channel. A meter tick then invalidates only the handful of leaf views
// that actually draw that channel's levels.

/// Whether the channel's device is currently delivering audio.
@MainActor
final class ChannelConnectionSource: ObservableObject {
    @Published private(set) var connected = false

    func publish(_ next: Bool) {
        if next != connected { connected = next }
    }
}

/// Engine-wide counters. Observed only by the status line and its detail popover.
@MainActor
final class DiagnosticsSource: ObservableObject {
    @Published private(set) var value = EngineDiagnostics()

    func publish(_ next: EngineDiagnostics) {
        if next != value { value = next }
    }
}

/// Owns the per-channel sources. Deliberately *not* an `ObservableObject`:
/// nothing should observe the hub itself, or we would be back to invalidating
/// the whole tree. Views resolve a stable per-channel object and observe that.
@MainActor
final class MeterHub {
    let diagnostics = DiagnosticsSource()


    private var sources: [String: ChannelConnectionSource] = [:]
    private var meterSources: [String: ChannelMeterSource] = [:]
    private let idleMeters = ChannelMeterSource()

    /// Returned for channels that no longer exist, so a view can always resolve
    /// something stable rather than creating objects during a body evaluation.
    private let idle = ChannelConnectionSource()

    func connection(for uid: String) -> ChannelConnectionSource {
        sources[uid] ?? idle
    }

    func meterSource(for uid: String) -> ChannelMeterSource {
        meterSources[uid] ?? idleMeters
    }

    /// Called when the set of channels changes, never from a view body.
    func ensure(uids: [String]) {
        for uid in uids where sources[uid] == nil {
            sources[uid] = ChannelConnectionSource()
            meterSources[uid] = ChannelMeterSource()
        }
        let live = Set(uids)
        for uid in sources.keys where !live.contains(uid) {
            sources.removeValue(forKey: uid)
            meterSources.removeValue(forKey: uid)
        }
    }

    func publishConnection(_ connected: Bool, for uid: String) {
        sources[uid]?.publish(connected)
    }

    func publishMeters(_ meters: ChannelMeters, for uid: String) {
        meterSources[uid]?.publish(meters)
    }
}
