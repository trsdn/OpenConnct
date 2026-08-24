/// The switches on a microphone's own body, as the microphone reports them.
///
/// Read-only, and that is a finding rather than a limitation of this type. The
/// vendor control channel these come from was mapped in full, and no command
/// that sets them exists — not in this app, and not in the manufacturer's own
/// software either. `docs/device-control.md` carries the evidence.
///
/// So this is not a control surface. It is the answer to a question the app
/// previously had to ask the user in words: *is your microphone already doing
/// this?*
public struct MicBodySwitches: Equatable, Sendable {
    /// The microphone's own fixed attenuation, ahead of its preamp.
    public var padEnabled: Bool
    /// The microphone's own high-pass, in hertz. `nil` means off.
    public var highPassHz: Int?
    /// A treble lift some microphones offer on a long press.
    public var highBoostEnabled: Bool
    /// A second, quieter copy of the signal recorded in parallel, used to
    /// recover a take that clipped. Reported here for completeness; the app has
    /// no equivalent and does not act on it.
    public var safetyChannelEnabled: Bool

    public init(
        padEnabled: Bool = false,
        highPassHz: Int? = nil,
        highBoostEnabled: Bool = false,
        safetyChannelEnabled: Bool = false
    ) {
        self.padEnabled = padEnabled
        self.highPassHz = highPassHz
        self.highBoostEnabled = highBoostEnabled
        self.safetyChannelEnabled = safetyChannelEnabled
    }

    /// Which property number carries which switch.
    ///
    /// Established by watching the reported values while the buttons were
    /// pressed, and confirmed against the printed instructions: one button
    /// cycles pad and safety channel together in four steps, and that exact
    /// four-step pattern appeared across properties 0 and 6. Property 1 is the
    /// only three-valued setting on the device, which is what a three-position
    /// filter looks like.
    public enum Property: UInt8, CaseIterable, Sendable {
        case pad = 0
        case highPass = 1
        case highBoost = 2
        case safetyChannel = 6
    }

    /// Folds one reported value into the state.
    ///
    /// Values arrive one property at a time and in no guaranteed order, so this
    /// is written as an update of a single field rather than as a decoder for a
    /// whole block. Unknown values are treated as off rather than ignored: a
    /// filter setting this app does not recognise is one it cannot claim the
    /// microphone is applying at a frequency the app also offers, so the honest
    /// reading is "not one of ours".
    public mutating func apply(_ property: Property, value: UInt8) {
        switch property {
        case .pad: padEnabled = value != 0
        case .highPass: highPassHz = Self.highPassFrequency(for: value)
        case .highBoost: highBoostEnabled = value != 0
        case .safetyChannel: safetyChannelEnabled = value != 0
        }
    }

    /// The two frequencies the hardware offers, which are also the two this app
    /// offers — which is exactly why reading them matters.
    static func highPassFrequency(for value: UInt8) -> Int? {
        switch value {
        case 1: return 75
        case 2: return 150
        default: return nil
        }
    }

    /// Whether the microphone is already cutting at the frequency the app is
    /// about to cut at.
    ///
    /// The app offers 75 Hz and 150 Hz because those are the frequencies
    /// printed on the hardware. Set in both places, the signal is filtered
    /// twice: the voice loses body and nothing on screen explains it. This is
    /// the check that lets the app say so.
    public func duplicatesHighPass(appHighPassHz: Int?) -> Bool {
        guard let mine = highPassHz, let theirs = appHighPassHz else { return false }
        return mine == theirs
    }

    /// Whether pad is set in both places, which is the same mistake as above and
    /// costs a further 20 dB of signal.
    public func duplicatesPad(appPadEnabled: Bool) -> Bool {
        padEnabled && appPadEnabled
    }
}
