import Foundation

// MARK: - Guided gain calibration
//
// Gain is the one control that has to be right before anything else can be,
// and it is the one control a level meter cannot help with. A meter *reports*:
// it says "quiet", which covers everything from 3 dB low to 30 dB low. It also
// cannot be read while you speak normally, because watching a meter changes how
// you speak.
//
// So the app measures instead: a short silence to find the room, then a spoken
// sentence to find the voice, and arithmetic in between. That arithmetic lives
// here, apart from the microphone, so every branch — including every refusal —
// is testable against a table.
//
// The band is passed in rather than restated. It is defined once, for the level
// meter, and a calibration that aimed at its own private idea of "correct"
// would drift away from the picture the user is looking at.

/// What the measurement concluded. Deliberately an enum rather than a number
/// plus flags: a calibration that always produces a gain figure sometimes
/// produces a wrong one, and the cases below are the situations where the
/// honest answer is not a gain figure at all.
public enum GainCalibrationOutcome: Equatable, Sendable {
    /// Change the gain to this value; the voice will then peak at roughly
    /// `resultingPeakDB`.
    case adjust(newGainDB: Float, resultingPeakDB: Float)

    /// The voice already peaks inside the target band. Nothing to do.
    case alreadyGood

    /// Too loud, and gain is not the answer.
    ///
    /// `atTheMicrophone` distinguishes the two very different reasons. When the
    /// signal arriving from the device is itself at full scale, its own preamp
    /// or converter is overloaded — turning our gain down cannot undo that,
    /// because the peaks were already flattened before we saw them. The answer
    /// is the pad, or the microphone's own pad switch, or backing off its dial.
    /// Otherwise it is simply our own gain set far too high, and lowering it
    /// would work if the range allowed.
    case tooLoud(atTheMicrophone: Bool)

    /// Even the highest gain available leaves the voice below the band. The
    /// microphone is too far away, or its own dial is down. Reported with the
    /// best that can be done, because that is still better than nothing.
    case notEnoughGain(bestGainDB: Float, resultingPeakDB: Float)

    /// Nothing that looks like speech happened during the measurement.
    case nothingHeard
}

/// The outcome plus the measurements it was derived from, so the interface can
/// show its working rather than a bare instruction.
public struct GainCalibrationResult: Equatable, Sendable {
    public let outcome: GainCalibrationOutcome
    /// High percentile of the held peak while the sentence was spoken, at the
    /// tap the target band is defined against (after gain and pad, before the
    /// effects and the fader).
    public let speechPeakDB: Float
    /// The same statistic measured over the preceding silence.
    public let noiseFloorDB: Float
    public let currentGainDB: Float

    /// How far the voice stands above the room.
    ///
    /// Note this is invariant under gain: turning the gain up lifts the voice
    /// and the room together. That is exactly why it is worth reporting
    /// separately — it is the one number the calibration cannot improve.
    public var signalToNoiseDB: Float { speechPeakDB - noiseFloorDB }

    /// True when the room is loud enough relative to the voice to be worth
    /// mentioning. Advisory only: the gain answer is still correct.
    public let noisy: Bool

    public init(outcome: GainCalibrationOutcome,
                speechPeakDB: Float,
                noiseFloorDB: Float,
                currentGainDB: Float,
                noisy: Bool) {
        self.outcome = outcome
        self.speechPeakDB = speechPeakDB
        self.noiseFloorDB = noiseFloorDB
        self.currentGainDB = currentGainDB
        self.noisy = noisy
    }
}

public enum GainCalibration {
    /// Below this much separation between the *sustained* level of the sentence
    /// and the room, nothing was said.
    ///
    /// Note which two numbers this compares, because the obvious pair is wrong.
    /// Comparing the loudest part of the sentence against the room asks "was
    /// there a loud moment", and a door closing passes that. Measured here, a
    /// silent five seconds still produced 7 dB of peak-over-room from ordinary
    /// creaks and taps, and the calibration duly proposed a gain for an empty
    /// chair.
    ///
    /// Speech is distinguishable from a room not by being louder at its peak
    /// but by *staying* loud: a talker fills most of the window, a tap fills a
    /// fraction of it. So the test is a middling percentile of the sentence —
    /// a level that has to be held, not merely touched — against the room.
    ///
    /// Kept low on purpose even so. A distant microphone at low gain gives a
    /// genuinely quiet but perfectly usable measurement, and refusing that
    /// would refuse the very case the feature exists for.
    public static let minimumSustainedAboveRoomDB: Float = 6

    /// Below this much separation, the gain answer is still right but the room
    /// is worth mentioning, because no gain setting will improve it.
    public static let noiseAdvisoryDB: Float = 20

    /// Gain proposals are rounded to this step. The readout shows one decimal
    /// and the buttons move in 1 dB, so finer than a half is invented precision.
    public static let gainStepDB: Float = 0.5

    /// The value at the given percentile, 0…1, of a set of readings.
    ///
    /// A high percentile rather than the maximum, because a two-to-five second
    /// window reliably contains one chair creak or one keyboard tap, and the
    /// maximum of that is a measurement of the furniture. A mean would be worse
    /// still — it would measure the pauses between words.
    public static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(p, 0), 1)
        let index = Int((clamped * Float(sorted.count - 1)).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// - Parameters:
    ///   - speechPeakDB: high percentile of the peak while speaking, measured
    ///     after gain and pad. This is the quantity the target band describes.
    ///   - sustainedSpeechDB: a middling percentile of the same window — the
    ///     level the voice held rather than the level it touched. Used only to
    ///     decide whether anything was said at all.
    ///   - noiseFloorDB: the *middle* of the preceding silence, not a high
    ///     percentile of it. See `GainCalibrationSession.silencePercentile`.
    ///   - rawPeakDB: the peak of the signal as the device delivered it, before
    ///     our gain. Only used to tell an overloaded microphone apart from our
    ///     own gain being too high — two problems with different answers.
    ///   - currentGainDB: the channel's total gain during the measurement.
    ///   - gainRange: the usable total gain for this channel.
    ///   - targetLowDB/targetHighDB: the meter's target band. Passed in, never
    ///     restated, so the words and the picture cannot disagree.
    ///   - clipDB: the level at which the meter calls something clipped.
    public static func evaluate(speechPeakDB: Float,
                                sustainedSpeechDB: Float,
                                noiseFloorDB: Float,
                                rawPeakDB: Float,
                                currentGainDB: Float,
                                gainRange: ClosedRange<Float>,
                                targetLowDB: Float,
                                targetHighDB: Float,
                                clipDB: Float) -> GainCalibrationResult {
        let snr = speechPeakDB - noiseFloorDB

        func result(_ outcome: GainCalibrationOutcome, noisy: Bool) -> GainCalibrationResult {
            GainCalibrationResult(outcome: outcome,
                                  speechPeakDB: speechPeakDB,
                                  noiseFloorDB: noiseFloorDB,
                                  currentGainDB: currentGainDB,
                                  noisy: noisy)
        }

        // Nothing was said. Checked first: every branch below would otherwise
        // happily propose a large boost of an empty room.
        guard sustainedSpeechDB - noiseFloorDB >= minimumSustainedAboveRoomDB else {
            return result(.nothingHeard, noisy: false)
        }

        let noisy = snr < noiseAdvisoryDB

        // The microphone itself is overloaded. This has to be checked before
        // anything involving our gain, because the damage happened upstream of
        // it and no setting here can undo it.
        if rawPeakDB >= clipDB {
            return result(.tooLoud(atTheMicrophone: true), noisy: noisy)
        }

        if speechPeakDB >= targetLowDB && speechPeakDB < targetHighDB {
            return result(.alreadyGood, noisy: noisy)
        }

        // Aim at the middle of the band rather than either edge, so that a
        // laugh or a raised voice has somewhere to go and a quiet aside does
        // not disappear.
        let target = (targetLowDB + targetHighDB) / 2
        let ideal = currentGainDB + (target - speechPeakDB)
        let clampedIdeal = min(max(ideal, gainRange.lowerBound), gainRange.upperBound)
        let newGain = (clampedIdeal / gainStepDB).rounded() * gainStepDB
        let resulting = speechPeakDB + (newGain - currentGainDB)

        if resulting >= targetHighDB {
            // Gain cannot come down far enough. Our own gain is too high and
            // the range will not let it go lower; the pad is what is left.
            return result(.tooLoud(atTheMicrophone: false), noisy: noisy)
        }
        if resulting < targetLowDB {
            return result(.notEnoughGain(bestGainDB: newGain, resultingPeakDB: resulting),
                          noisy: noisy)
        }
        return result(.adjust(newGainDB: newGain, resultingPeakDB: resulting), noisy: noisy)
    }
}
