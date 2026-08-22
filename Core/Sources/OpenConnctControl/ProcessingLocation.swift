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
    /// Pad and high-pass are unconditionally software. That is not an oversight
    /// and not a to-do: probing every device-level control CoreAudio publishes —
    /// across all scopes and elements — found gain, mute and direct monitoring,
    /// and nothing else. There is no public property for a pad or a high-pass,
    /// so an honest interface says the app does them.
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
}
