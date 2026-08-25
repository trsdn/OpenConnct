import SwiftUI

// MARK: - dB to position mapping
//
// A linear map over -120…0 dBFS makes speech (typically -30…-12 dBFS) occupy
// only the top quarter of the meter. Instead we use a piecewise mapping:
//   • Anything at or below -60 dB → position 0 (invisible floor)
//   • -60 → 0, 0 → 1 but with a power curve (exponent 2.0) so that
//     the -18 dBFS bottom of the target band lands at ~49 % and its -6 dBFS
//     top lands at ~81 %, giving good visual resolution where speech energy
//     actually lives. Speech (-30…-12 dBFS) occupies the 25–64 % band of the
//     meter, with clear headroom visible in the top third before clipping.
//
// The target band and the amber/red boundaries are fixed physical dBFS values;
// their pixel positions are computed by the same meterPosition() function so
// the bands always match the tick marks.

/// The bottom of the meter's scale. Anything at or below this is "nothing",
/// and the meter shows nothing for it — no bar, and no hold mark either.
/// `meterVerdict` uses the same number, so the words and the picture agree
/// about where silence begins.
let meterFloorDB: Float = -60

/// Maps a dBFS value in -60…0 to a 0…1 fraction using a quadratic curve.
/// Exponent 2.0 places the -18 dBFS amber threshold at ~49 % and the -6 dBFS
/// red threshold at ~81 %, giving comfortable resolution across the speech
/// operating range. The curve is monotonic and returns exactly 0 at −60 dBFS
/// and exactly 1 at 0 dBFS, with no NaN or out-of-range values at the extremes.
func meterPosition(_ db: Float) -> CGFloat {
    let clamped = max(meterFloorDB, min(0, db))
    let linear = Double((clamped - meterFloorDB) / -meterFloorDB) // 0…1 linear
    return CGFloat(pow(linear, 2.0))                          // compress quiet floor, expand speech range
}

// MARK: - Orientation

enum MeterOrientation { case vertical, horizontal }

// MARK: - Colour breakpoints
//
// Fixed physical dBFS values. Their pixel positions come from meterPosition()
// so the colour bands always line up with the level they claim to mark.
//
// These used to be amber at -18 and red at -6, which made the *correct* level
// for speech light up as a warning: a user aiming for "all green" would end up
// around -25 dBFS, far too quiet, and would have no way to know that from the
// meter. Amber and red now mean what they say — running hot, and close to
// clipping — and the level you should actually be aiming for is marked
// separately as the target band below.

let meterAmberDB: Float = -6
let meterRedDB: Float   = -1

// MARK: - Target band
//
// Where a speaking voice should sit. -18…-6 dBFS peak is the long-standing
// broadcast convention for a live voice channel: loud enough to sit well above
// the noise floor and to survive the conferencing app's own processing, with
// enough headroom left that a laugh or a raised voice does not clip.
//
// This is drawn into the meter track itself rather than written down somewhere,
// because "where should the bar be?" is a question about a picture and deserves
// a pictorial answer.

let meterTargetLowDB: Float  = -18
let meterTargetHighDB: Float = -6

/// Ticks drawn across the meter track so a position can be read as a number.
/// Kept sparse: a scale with a mark every 6 dB is a texture, not a scale.
let meterTickDB: [Float] = [-40, -30, -20, -12, -6]

/// Plain-language verdict on a peak level, for the readout beside the meter.
/// The thresholds match the target band exactly, so the words and the picture
/// can never disagree.
enum MeterVerdict {
    case silent, tooQuiet, good, hot, clipping

    var text: String {
        switch self {
        case .silent:   return "silent"
        case .tooQuiet: return "quiet"
        case .good:     return "good"
        case .hot:      return "loud"
        case .clipping: return "too loud"
        }
    }
}

func meterVerdict(peakDB: Float) -> MeterVerdict {
    if peakDB <= meterFloorDB { return .silent }
    if peakDB < meterTargetLowDB { return .tooQuiet }
    if peakDB < meterTargetHighDB { return .good }
    if peakDB < meterRedDB { return .hot }
    return .clipping
}

// MARK: - Gain reduction mapping

/// Maps gain reduction 0…30 dB to a 0…1 fill using an exponent below one.
/// This intentionally differs from the level meter's exponent-2 curve: for gain
/// reduction we want small amounts (1–3 dB) to be clearly visible, which means
/// expanding the low end rather than compressing it.
func reductionFraction(_ reductionDB: Float) -> CGFloat {
    let clamped = max(0, min(30, reductionDB))
    let linear  = Double(clamped / 30)
    return CGFloat(pow(linear, 0.55))
}

// The meters themselves are AppKit views; see MeterNSView.swift for why. The
// mapping functions above stay here because they are pure, shared, and unit
// tested independently of any drawing.
