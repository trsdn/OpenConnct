import Foundation

// Splitting one gain figure between the microphone and the DSP.
//
// The user sets a single number. Where that gain is actually applied is an
// implementation detail they should never have to think about, but it is not a
// detail acoustically: gain applied inside the microphone happens *before* its
// converter, so it lifts the signal without lifting the converter's own noise.
// The same gain applied afterwards in software lifts both. Whatever the device
// can contribute is therefore worth taking.
//
// Nothing here talks to CoreAudio. It is arithmetic on decibels, so it can be
// tested against a table of expected values instead of against a microphone
// that may or may not be plugged in.

/// What a device's own input gain stage can do.
///
/// `stepDB` matters more than it looks. USB audio devices quantise gain to
/// whole steps and silently round a request, so asking for 26.4 dB and assuming
/// you got it leaves the total gain wrong by the rounding error. Quantising up
/// front makes the request honest.
public struct HardwareGainRange: Equatable, Sendable {
    public var minDB: Float
    public var maxDB: Float
    public var stepDB: Float

    public init(minDB: Float, maxDB: Float, stepDB: Float = 1) {
        self.minDB = minDB
        self.maxDB = maxDB
        self.stepDB = max(stepDB, 0)
    }

    /// The nearest value the device can actually produce.
    public func quantised(_ db: Float) -> Float {
        let clamped = min(max(db, minDB), maxDB)
        guard stepDB > 0 else { return clamped }
        let steps = (clamped - minDB) / stepDB
        return min(max(minDB + steps.rounded() * stepDB, minDB), maxDB)
    }
}

/// How one gain figure is realised.
public struct GainSplit: Equatable, Sendable {
    /// What the device should be asked for, or `nil` when there is no device
    /// stage to ask.
    public var hardwareDB: Float?
    /// What the DSP must apply so that the two together come to the total.
    public var softwareDB: Float

    public init(hardwareDB: Float?, softwareDB: Float) {
        self.hardwareDB = hardwareDB
        self.softwareDB = softwareDB
    }
}

public enum HardwareGainSplitter {
    /// The device gain we would like, for a given total.
    ///
    /// Push as much as the device will take, because every decibel moved into
    /// the device is a decibel of converter noise not amplified. Two cases are
    /// worth naming:
    ///
    /// - A *negative* total cannot go into a device whose range starts at 0 dB.
    ///   It asks for the minimum and leaves the attenuation to the DSP, which
    ///   has no lower limit.
    /// - A total *above* the device maximum takes the maximum and leaves the
    ///   remainder to the DSP. The user is not told the device ran out; they
    ///   asked for a level, not for a particular way of reaching it.
    public static func target(totalDB: Float, range: HardwareGainRange?) -> Float? {
        guard let range else { return nil }
        return range.quantised(totalDB)
    }

    /// What the DSP must apply *right now*, given what the device currently
    /// reports.
    ///
    /// This deliberately takes the device's actual gain rather than the value
    /// that was requested, and it is the whole reason the total never audibly
    /// jumps. Setting device gain over USB was measured at up to a full second
    /// on real hardware, so a request and its effect are separated by a long,
    /// variable delay. If the DSP were set from the *requested* device gain, the
    /// level would be wrong for that entire window.
    ///
    /// Deriving it from the reported value instead means the total is correct at
    /// every instant: while the device is still moving, the DSP holds the
    /// difference. It also answers the question of who owns the value — if some
    /// other application, or a control on the device itself, changes the gain,
    /// the same arithmetic absorbs it and the user hears no change at all.
    public static func compensate(totalDB: Float, hardwareDB: Float?) -> GainSplit {
        guard let hardwareDB else {
            return GainSplit(hardwareDB: nil, softwareDB: totalDB)
        }
        return GainSplit(hardwareDB: hardwareDB, softwareDB: totalDB - hardwareDB)
    }

    /// The settled case: what the split looks like once the device has reached
    /// the value it was asked for. Used by tests and by the UI's explanatory
    /// readout, never to drive the DSP — see `compensate` for why.
    public static func settled(totalDB: Float, range: HardwareGainRange?) -> GainSplit {
        compensate(totalDB: totalDB, hardwareDB: target(totalDB: totalDB, range: range))
    }

    /// Converts a gain figure from the old meaning to the new one, once.
    ///
    /// Before the device's own gain stage was used, this number was a DSP trim
    /// sitting on top of whatever the microphone's preamp happened to be set to.
    /// It is now the whole amount, split between the two. Reading an old value
    /// under the new meaning would be a silent, large level change on first
    /// launch — on the hardware this was developed against, a typical channel
    /// would have dropped by 26 dB, because that range *is* the preamp and at
    /// its minimum the microphone is very nearly deaf.
    ///
    /// Folding the device's current gain into the number instead means the first
    /// launch changes nothing audible, and every launch after it treats the
    /// number as the absolute total.
    public static func adoptedTotal(previousTotalDB: Float, reportedHardwareDB: Float) -> Float {
        previousTotalDB + reportedHardwareDB
    }
}
