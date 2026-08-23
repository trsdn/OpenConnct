/// Where a control actually takes effect: inside the microphone, or in this
/// app's own processing.
///
/// This exists as a value rather than as a condition inside a view because it is
/// a claim about the signal path, and claims about the signal path should be
/// checkable. It is also the seam that will make future hardware support show up
/// in the interface on its own: when a control gains a device-backed
/// implementation, the badge follows from this rather than from remembering to
/// change a view.
public enum ProcessingLocation: Equatable, Sendable {
    /// The microphone does it, ahead of its own converter.
    case device
    /// This app does it, after the signal has already been digitised.
    case software

    /// Deliberately short. These sit next to controls, and a chip wide enough to
    /// read "Processed in software" would compete with the control it describes.
    public var badgeText: String {
        switch self {
        case .device: return "MIC"
        case .software: return "APP"
        }
    }

    public var isDevice: Bool { self == .device }
}

/// Which parts of a channel run where.
///
/// Only the preamp-family controls are described: gain, pad and high-pass are
/// the three a microphone might plausibly do itself, so they are the three where
/// the question arises. Gate, compressor and the two tone stages are not
/// included because no USB microphone offers them and a badge saying so would be
/// noise rather than information.
public struct ChannelProcessingMap: Equatable, Sendable {
    public var gain: ProcessingLocation
    public var pad: ProcessingLocation
    public var highPass: ProcessingLocation

    public init(gain: ProcessingLocation, pad: ProcessingLocation, highPass: ProcessingLocation) {
        self.gain = gain
        self.pad = pad
        self.highPass = highPass
    }

    /// Works out where each control runs for one microphone.
    ///
    /// - Parameters:
    ///   - hardwareGainRange: the device's own gain stage, if it has one.
    ///   - hardwareGainEnabled: whether the user allows this app to drive it.
    ///
    /// Pad and high-pass are unconditionally software, and the reason is narrower
    /// than it first appears. Probing every device-level control CoreAudio
    /// publishes — across all scopes and elements — found gain, mute and direct
    /// monitoring, and nothing else. That establishes that no pad or high-pass is
    /// reachable *by that route*, which is what governs what this app can offer
    /// today.
    ///
    /// There is a second route. Both microphones this was developed against also
    /// expose a vendor control channel, and its transport is now fully mapped —
    /// see `docs/device-control.md`. What is not yet known is what its properties
    /// mean, so nothing writes to it. When a control gains a device-backed
    /// implementation, it changes here and the interface follows.
    ///
    /// `.software` therefore means "this control is ours", never "your
    /// microphone cannot do this" — see `bodySwitchNote`, which exists precisely
    /// because the two can both be on at once.
    public static func resolve(
        hardwareGainRange: HardwareGainRange?,
        hardwareGainEnabled: Bool
    ) -> ChannelProcessingMap {
        let gainRunsOnDevice = hardwareGainRange != nil && hardwareGainEnabled
        return ChannelProcessingMap(
            gain: gainRunsOnDevice ? .device : .software,
            pad: .software,
            highPass: .software)
    }

    /// A caution to show when the user has switched on a stage that their
    /// microphone may *also* be applying on its own.
    ///
    /// This is the one place where the honest answer is "we cannot tell you".
    /// A microphone with a filter button on its body applies that filter before
    /// the signal reaches the computer, and reports nothing about it — there is
    /// no property to read. So a microphone set to cut at 75 Hz, feeding this app
    /// also set to cut at 75 Hz, produces a thin voice and no clue as to why.
    ///
    /// The note is shown only while the relevant stage is on. Permanently
    /// visible, it would be wallpaper on the many microphones that have no such
    /// switch; shown on demand, it appears exactly when the mistake is possible.
    ///
    /// Returns `nil` when neither stage is active.
    public static func bodySwitchNote(padEnabled: Bool, highPassActive: Bool) -> String? {
        switch (highPassActive, padEnabled) {
        case (false, false):
            return nil
        case (true, false):
            return "Some microphones have their own filter switch on the body. "
                + "If yours is set, both apply."
        case (false, true):
            return "Some microphones have their own pad switch on the body. "
                + "If yours is set, both apply."
        case (true, true):
            return "Some microphones have filter and pad switches on the body. "
                + "If yours are set, both apply."
        }
    }
}
