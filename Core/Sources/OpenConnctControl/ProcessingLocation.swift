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
    /// There is a second route, and it has now been followed to its end. Both
    /// microphones this was developed against expose a vendor control channel;
    /// it is fully mapped, and four of its properties are the switches on the
    /// microphone's body. They can be **read and not written** — no command to
    /// set them exists, in this app or in the manufacturer's own software. See
    /// `docs/device-control.md` for the evidence, which is a negative result and
    /// therefore carries its own corroboration.
    ///
    /// So that route changes nothing here: a control the app cannot operate
    /// cannot be moved to the device. What it changes is `bodySwitchNote`, which
    /// no longer has to guess.
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
    /// A microphone with a filter switch on its body applies that filter before
    /// the signal ever reaches the computer. Set there and set here, the signal
    /// is cut twice: the voice goes thin and nothing on screen explains it. The
    /// pad is the same mistake and costs a further 20 dB.
    ///
    /// - Parameter reported: what the microphone says its own switches are
    ///   doing, or `nil` when it cannot be asked — which is the case for most
    ///   microphones, and for these ones while the control channel is not yet
    ///   answering.
    ///
    /// The two cases are answered differently on purpose. Unknown, the note has
    /// to hedge, and hedged text is only worth showing while the mistake is
    /// actually possible — so it appears when a stage is on and not otherwise.
    /// Known, the note stops hedging: it warns when the stages really are
    /// stacked, and says nothing at all when they are not. Silence is the
    /// improvement. A caution shown on every microphone that has no such switch
    /// is wallpaper, and wallpaper is what people learn to stop reading.
    ///
    /// Returns `nil` when there is nothing to say.
    public static func bodySwitchNote(
        padEnabled: Bool,
        highPassActive: Bool,
        reported: MicBodySwitches? = nil
    ) -> String? {
        guard let reported else {
            return unknownBodySwitchNote(padEnabled: padEnabled, highPassActive: highPassActive)
        }
        let padStacked = reported.duplicatesPad(appPadEnabled: padEnabled)
        // Deliberately not `duplicatesHighPass`: the app's cut frequency is not
        // available here, and stacking two *different* cuts is also worth
        // warning about — 75 Hz under 150 Hz still removes more than intended.
        let filterStacked = highPassActive && reported.highPassHz != nil

        switch (filterStacked, padStacked) {
        case (false, false):
            return nil
        case (true, false):
            let hz = reported.highPassHz ?? 0
            return "Your microphone is also filtering at \(hz) Hz. Both apply."
        case (false, true):
            return "Your microphone's own pad is on. Both apply."
        case (true, true):
            let hz = reported.highPassHz ?? 0
            return "Your microphone's own pad is on and it is filtering at "
                + "\(hz) Hz. Both apply."
        }
    }

    /// The wording used when the microphone cannot be asked.
    ///
    /// Kept separate so that the hedging lives in one place and is obviously the
    /// fallback rather than the normal case.
    private static func unknownBodySwitchNote(
        padEnabled: Bool,
        highPassActive: Bool
    ) -> String? {
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
