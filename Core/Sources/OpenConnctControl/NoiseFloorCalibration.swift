import Foundation

// MARK: - Measuring a room to choose a gate threshold
//
// The noise gate ships with one threshold for every microphone, and there is no
// such number. The right value depends on the capsule, its preamp, how far away
// the talker sits and how loud the room is — a combination the app can measure
// in two seconds and a user cannot reasonably be asked to derive from a meter.
//
// The default was -45 dBFS. On the machine this was written on, one attached
// input has a floor of around -37 dBFS: eight decibels *above* the default. A
// gate set there can never close. The user sees a switched-on effect doing
// nothing at all, with nothing on screen to explain why.
//
// The arithmetic lives here, away from any microphone, so that every branch —
// especially every refusal — is testable against a table.
//
// ## Why this uses a high percentile when the gain calibration uses the middle
//
// They look contradictory and are not. The gain calibration asks "how loud is
// this room, normally", and the middle of the distribution answers that; a high
// percentile would answer "how loud was the worst tap", which is not the room.
//
// This one asks a different question: "what does the threshold have to clear so
// the gate stays shut". The gate opens on a single excursion above the
// threshold — that is its entire mechanism — so the excursions are precisely
// what must be measured. The middle would produce a threshold the room walks
// over several times a second.
//
// It is still a percentile rather than the maximum, for the reason the maximum
// is never used anywhere in this app: one door, one dropped pen, and the
// threshold is set for an event that happens once an hour. Letting the rare
// loudest moments through is the right trade — the gate opening briefly on a
// bang is barely noticeable, whereas a gate that clips the start of every
// sentence is unusable.

/// What the measurement concluded.
public enum NoiseFloorOutcome: Equatable, Sendable {
    /// Set the threshold here. `floorDB` is what was measured, `marginDB` what
    /// was added.
    case propose(thresholdDB: Float)

    /// The room is loud enough that no threshold separates it from speech.
    ///
    /// Reported instead of a number because the number would be actively
    /// harmful: a threshold set above a floor this high sits inside the range
    /// ordinary speech occupies, and the gate would cut the quiet ends of words.
    /// The fix is the microphone or where it is standing, not this setting.
    case roomTooLoud

    /// The proposed threshold would sit above the top of the control's range,
    /// which is the same situation as `roomTooLoud` arriving by arithmetic.
    case aboveRange

    /// The channel produced nothing at all — no signal reached the probe.
    case nothingMeasured
}

/// The outcome and the measurement behind it, so the interface can show its
/// working instead of issuing an instruction.
public struct NoiseFloorResult: Equatable, Sendable {
    public let outcome: NoiseFloorOutcome
    /// The measured floor, in the gate's own detector frame: high-passed at
    /// 120 Hz, envelope-followed, after gain and pad. Not comparable with a
    /// level meter reading, and deliberately never shown next to one.
    public let floorDB: Float
    public let previousThresholdDB: Float

    public init(outcome: NoiseFloorOutcome, floorDB: Float, previousThresholdDB: Float) {
        self.outcome = outcome
        self.floorDB = floorDB
        self.previousThresholdDB = previousThresholdDB
    }
}

public enum NoiseFloorCalibration {
    /// How far above the measured floor the threshold is placed.
    ///
    /// A room is not stationary. A fan cycling on, a hard drive, a neighbour's
    /// chair — each is worth a few decibels, and a threshold sitting exactly on
    /// the floor would be crossed by all of them. Six decibels is roughly a
    /// doubling of amplitude, which is more than ordinary room variation and
    /// far less than the twenty-odd decibels that separate a room from speech.
    ///
    /// It is deliberately the same figure as the gate's default hysteresis, and
    /// that is not a coincidence worth removing: the gate closes at threshold
    /// minus hysteresis, so a margin equal to the hysteresis puts the *closing*
    /// threshold back down at the measured floor. The gate therefore opens well
    /// clear of the room but does not slam shut the instant a word tails off.
    public static let marginDB: Float = 6

    /// A floor above this cannot be gated usefully.
    ///
    /// Quiet speech at a sensible level occupies roughly -30 to -12 dBFS at the
    /// gate's input. A floor at -25 dB leaves a threshold at -19 dB, which is
    /// inside that range: the gate would be deciding between "quiet word" and
    /// "room" on a few decibels, and it would get it wrong in both directions.
    /// Better to say so.
    public static let unusableFloorDB: Float = -25

    /// Below this, the probe saw nothing — a disconnected or silent channel, not
    /// a very quiet room. Rooms do not reach this.
    public static let silenceDB: Float = -100

    /// Thresholds are rounded to this, matching the slider's readable precision.
    public static let stepDB: Float = 0.5

    /// - Parameters:
    ///   - floorDB: a high percentile of the probe's per-poll maximum over the
    ///     measured silence. See the note at the top of this file for why this
    ///     is a high percentile where the gain calibration uses the middle.
    ///   - previousThresholdDB: what the channel had, so the result can say
    ///     what changed.
    ///   - thresholdRange: the range the threshold control offers.
    public static func evaluate(floorDB: Float,
                                previousThresholdDB: Float,
                                thresholdRange: ClosedRange<Float>) -> NoiseFloorResult {
        func result(_ outcome: NoiseFloorOutcome) -> NoiseFloorResult {
            NoiseFloorResult(outcome: outcome,
                             floorDB: floorDB,
                             previousThresholdDB: previousThresholdDB)
        }

        guard floorDB > silenceDB else { return result(.nothingMeasured) }
        guard floorDB < unusableFloorDB else { return result(.roomTooLoud) }

        let raw = floorDB + marginDB
        let rounded = (raw / stepDB).rounded() * stepDB
        guard rounded <= thresholdRange.upperBound else { return result(.aboveRange) }

        // The lower bound is not a refusal. A very quiet room proposing a
        // threshold below what the control offers is a good problem: the bottom
        // of the range is then further below the room than asked for, and the
        // gate still closes.
        let threshold = max(rounded, thresholdRange.lowerBound)
        return result(.propose(thresholdDB: threshold))
    }

    /// How the proposal compares with what the channel already had.
    ///
    /// Here rather than with the rest of the wording in the app, because it is
    /// the one sentence with arithmetic in it, and arithmetic that is only
    /// exercised by reading it on screen is arithmetic nobody checks. `nil`
    /// when there is no proposal to compare.
    public static func changeDescription(_ result: NoiseFloorResult) -> String? {
        guard case let .propose(thresholdDB) = result.outcome else { return nil }
        let delta = thresholdDB - result.previousThresholdDB
        // Half a decibel is the step, so anything smaller is the same setting.
        guard abs(delta) >= stepDB else { return "That is what it was already set to." }
        let direction = delta > 0 ? "higher" : "lower"
        return String(format: "That is %.1f dB %@ than the current setting.", abs(delta), direction)
    }
}
