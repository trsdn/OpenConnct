import SwiftUI

// MARK: - dB to position mapping
//
// A linear map over -120…0 dBFS makes speech (typically -30…-12 dBFS) occupy
// only the top quarter of the meter. Instead we use a piecewise mapping:
//   • Anything at or below -60 dB → position 0 (invisible floor)
//   • -60 → 0, 0 → 1 but with a power curve (exponent 2.0) so that
//     the -18 dB amber threshold lands at ~0.49 and -6 dB lands at ~0.81,
//     giving good visual resolution where speech energy actually lives.
//     Speech (-30…-12 dBFS) occupies the 25–64 % band of the meter, with
//     clear headroom visible in the top third before clipping.
//
// The green/amber/red boundaries are fixed physical dBFS values; their pixel
// positions are computed by the same meterPosition() function so the colour
// bands always match the tick marks.

private let meterFloor: Float = -60

/// Maps a dBFS value in -60…0 to a 0…1 fraction using a quadratic curve.
/// Exponent 2.0 places the -18 dBFS amber threshold at ~49 % and the -6 dBFS
/// red threshold at ~81 %, giving comfortable resolution across the speech
/// operating range. The curve is monotonic and returns exactly 0 at −60 dBFS
/// and exactly 1 at 0 dBFS, with no NaN or out-of-range values at the extremes.
func meterPosition(_ db: Float) -> CGFloat {
    let clamped = max(meterFloor, min(0, db))
    let linear = Double((clamped - meterFloor) / -meterFloor) // 0…1 linear
    return CGFloat(pow(linear, 2.0))                          // compress quiet floor, expand speech range
}

// MARK: - Orientation

enum MeterOrientation { case vertical, horizontal }

// MARK: - Colour breakpoints
//
// Fixed physical dBFS values. Their pixel positions come from meterPosition()
// so the colour bands always line up with the level they claim to mark.

let meterAmberDB: Float = -18
let meterRedDB: Float   = -6

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
