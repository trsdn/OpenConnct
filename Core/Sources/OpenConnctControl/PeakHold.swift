import Foundation

/// A peak hold: the loudest value seen recently, held still for a while and
/// then allowed to fall at a fixed rate.
///
/// Two things in the interface need this and they must agree, so it lives here
/// rather than twice in the views: the thin mark on a level meter, and the
/// plain-language verdict beside it.
///
/// The verdict is the less obvious one. A peak meter's own fall is 300 ms,
/// which is about 29 dB per second — so a voice peaking correctly at −12 dBFS
/// reads −24 dBFS after a third of a second, and the word beside the meter
/// flips to "quiet" in every pause between sentences. The question that word
/// answers is "am I set right?", and the honest input to that question is the
/// loudest thing said recently, not the level at this instant.
///
/// Time is passed in rather than read, because the meter tick rate is settable
/// and because a hold that cannot be advanced by hand cannot be tested.
public struct PeakHold: Equatable {

    /// The held value, in dBFS.
    public private(set) var db: Float

    /// How long the value sits still before it begins to fall.
    public let holdSeconds: Double

    /// How fast it falls once it starts, in dB per second. Deliberately slower
    /// than the meter's own fall, so a mark and the bar under it stay visibly
    /// separate rather than travelling down together.
    public let fallDBPerSecond: Float

    private let floorDB: Float
    private var remaining: Double

    public init(floorDB: Float = -120,
                holdSeconds: Double = 1.5,
                fallDBPerSecond: Float = 12) {
        self.floorDB = floorDB
        self.db = floorDB
        self.holdSeconds = holdSeconds
        self.fallDBPerSecond = fallDBPerSecond
        self.remaining = 0
    }

    /// Folds one new reading in.
    ///
    /// - Parameters:
    ///   - peakDB: the meter's current peak, in dBFS.
    ///   - dt: seconds since the previous call. Callers should clamp this — a
    ///     window that was occluded, or a machine that slept, otherwise
    ///     produces one enormous step and the mark drops out of sight in a
    ///     single frame.
    public mutating func advance(to peakDB: Float, dt: Double) {
        if peakDB >= db {
            db = peakDB
            remaining = holdSeconds
            return
        }
        if remaining > 0 {
            remaining -= max(0, dt)
            return
        }
        // Never below the reading itself. A mark under the bar would be hidden
        // by it and, worse, would claim a level lower than the one on show.
        db = max(peakDB, db - Float(max(0, dt)) * fallDBPerSecond)
    }

    /// Drops the hold to the floor — for a channel going silent, or a meter
    /// being rebound to a different device, where carrying the old value over
    /// would show a level that is not there.
    public mutating func reset() {
        db = floorDB
        remaining = 0
    }
}
