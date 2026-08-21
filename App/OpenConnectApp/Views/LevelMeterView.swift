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

// MARK: - LevelMeterView
//
// Both meters are drawn with `Canvas` rather than nested Shape views inside a
// `GeometryReader`. They repaint 30 times a second, and as a view hierarchy
// each repaint pushed a fresh layout pass and a subgraph of rectangles through
// AttributeGraph. `Canvas` is a single drawing closure with no view graph at
// all, which is the difference between a meter costing a few percent of a core
// and costing a fraction of one.

/// Shows RMS as a solid bar and input peak as a thin held tick.
/// Orientation: .vertical for channel strips, .horizontal for detail view.
struct LevelMeterView: View {
    let rmsDB: Float
    let peakDB: Float
    let orientation: MeterOrientation
    var width: CGFloat = 8

    // Colour breakpoints
    private let amberDB: Float = -18
    private let redDB: Float   = -6

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let vertical = orientation == .vertical
            let length = vertical ? size.height : size.width
            let thickness = vertical ? size.width : size.height

            ctx.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                with: .color(Theme.meterTrack))

            let rmsLen = meterPosition(rmsDB) * length
            let amberPos = meterPosition(amberDB) * length
            let redPos = meterPosition(redDB) * length

            // The bar is drawn as three fixed colour bands clipped to the
            // current level, so a band boundary always sits at the same dBFS
            // value regardless of level.
            segment(ctx, from: 0, to: min(rmsLen, amberPos),
                    colour: Theme.meterGreen, vertical: vertical,
                    length: length, thickness: thickness)
            segment(ctx, from: amberPos, to: min(rmsLen, redPos),
                    colour: Theme.meterAmber, vertical: vertical,
                    length: length, thickness: thickness)
            segment(ctx, from: redPos, to: rmsLen,
                    colour: Theme.meterRed, vertical: vertical,
                    length: length, thickness: thickness)

            let peakPos = meterPosition(peakDB) * length
            let tickColour = peakDB > redDB ? Theme.meterRed
                           : peakDB > amberDB ? Theme.meterAmber
                           : Theme.meterGreen
            segment(ctx, from: peakPos, to: peakPos + 2,
                    colour: tickColour, vertical: vertical,
                    length: length, thickness: thickness)
        }
        .frame(width: orientation == .vertical ? width : nil,
               height: orientation == .vertical ? nil : width)
        .accessibilityHidden(true)
    }

    /// Fills the band between two distances measured from the meter's origin —
    /// the bottom edge when vertical, the leading edge when horizontal.
    private func segment(
        _ ctx: GraphicsContext, from: CGFloat, to: CGFloat, colour: Color,
        vertical: Bool, length: CGFloat, thickness: CGFloat
    ) {
        let lo = max(0, min(from, length))
        let hi = max(0, min(to, length))
        guard hi > lo else { return }

        let rect = vertical
            ? CGRect(x: 0, y: length - hi, width: thickness, height: hi - lo)
            : CGRect(x: lo, y: 0, width: hi - lo, height: thickness)
        ctx.fill(Path(rect), with: .color(colour))
    }
}

// MARK: - GainReductionMeterView

/// Draws gain reduction downward from the top of the bar.
/// `reductionDB` is expected as a non-negative value (e.g. 3.0 means -3 dB GR).
struct GainReductionMeterView: View {
    let reductionDB: Float
    let orientation: MeterOrientation
    var width: CGFloat = 6

    // Map reduction 0…30 dB to 0…1 fill using an exponent < 1 (0.55).
    // This intentionally differs from the level-meter's exponent-2 curve:
    // for gain-reduction we want small amounts (1–3 dB) to be clearly
    // visible, which requires expanding the low end rather than compressing it.
    private func reductionFraction(_ r: Float) -> CGFloat {
        let clamped = max(0, min(30, r))
        let linear  = Double(clamped / 30)
        return CGFloat(pow(linear, 0.55))
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            ctx.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                with: .color(Theme.meterTrack))

            let vertical = orientation == .vertical
            let length = vertical ? size.height : size.width
            let fillLen = reductionFraction(reductionDB) * length
            guard fillLen > 0 else { return }

            // Gain reduction reads as the bar eating into the track: downward
            // from the top when vertical, leftward from the right when not.
            let rect = vertical
                ? CGRect(x: 0, y: 0, width: size.width, height: fillLen)
                : CGRect(x: length - fillLen, y: 0, width: fillLen, height: size.height)
            ctx.fill(Path(rect), with: .color(Theme.meterAmber.opacity(0.8)))
        }
        .frame(width: orientation == .vertical ? width : nil,
               height: orientation == .vertical ? nil : width)
        .accessibilityHidden(true)
    }
}
