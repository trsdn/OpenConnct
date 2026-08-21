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
        GeometryReader { geo in
            let length = orientation == .vertical ? geo.size.height : geo.size.width
            let rmsFrac  = meterPosition(rmsDB)
            let peakFrac = meterPosition(peakDB)
            let rmsLen  = rmsFrac  * length
            let peakPos = peakFrac * length

            if orientation == .vertical {
                ZStack(alignment: .bottom) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.meterTrack)
                    // RMS bar
                    verticalRMSBar(length: length, rmsLen: rmsLen)
                    // Peak tick (2 px tall)
                    peakTick(length: length, pos: peakPos, isVertical: true)
                }
                .frame(width: width)
                .accessibilityHidden(true)
            } else {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.meterTrack)
                    horizontalRMSBar(length: length, rmsLen: rmsLen)
                    peakTick(length: length, pos: peakPos, isVertical: false)
                }
                .frame(height: width)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Vertical RMS bar (fills from bottom)
    @ViewBuilder
    private func verticalRMSBar(length: CGFloat, rmsLen: CGFloat) -> some View {
        let amberPos = meterPosition(amberDB) * length
        let redPos   = meterPosition(redDB)   * length

        // Green segment
        let greenHeight = min(rmsLen, amberPos)
        if greenHeight > 0 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Theme.meterGreen)
                    .frame(width: width, height: greenHeight)
            }
        }
        // Amber segment
        let amberHeight = max(0, min(rmsLen, redPos) - amberPos)
        if amberHeight > 0 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Theme.meterAmber)
                    .frame(width: width, height: amberHeight)
                    .offset(y: 0)
            }
            .frame(height: amberPos + amberHeight, alignment: .bottom)
        }
        // Red segment
        let redHeight = max(0, rmsLen - redPos)
        if redHeight > 0 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Theme.meterRed)
                    .frame(width: width, height: redHeight)
            }
            .frame(height: redPos + redHeight, alignment: .bottom)
        }
    }

    // MARK: Horizontal RMS bar (fills from left)
    @ViewBuilder
    private func horizontalRMSBar(length: CGFloat, rmsLen: CGFloat) -> some View {
        let amberPos = meterPosition(amberDB) * length
        let redPos   = meterPosition(redDB)   * length

        let greenWidth = min(rmsLen, amberPos)
        if greenWidth > 0 {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.meterGreen)
                    .frame(width: greenWidth, height: width)
                Spacer(minLength: 0)
            }
        }
        let amberWidth = max(0, min(rmsLen, redPos) - amberPos)
        if amberWidth > 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(width: amberPos)
                Rectangle()
                    .fill(Theme.meterAmber)
                    .frame(width: amberWidth, height: width)
                Spacer(minLength: 0)
            }
        }
        let redWidth = max(0, rmsLen - redPos)
        if redWidth > 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(width: redPos)
                Rectangle()
                    .fill(Theme.meterRed)
                    .frame(width: redWidth, height: width)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Peak tick
    @ViewBuilder
    private func peakTick(length: CGFloat, pos: CGFloat, isVertical: Bool) -> some View {
        let tickColor = peakDB > redDB ? Theme.meterRed
                      : peakDB > amberDB ? Theme.meterAmber
                      : Theme.meterGreen

        if isVertical {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(tickColor)
                    .frame(width: width, height: 2)
            }
            .frame(height: pos + 2, alignment: .bottom)
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(width: max(0, pos - 1))
                Rectangle()
                    .fill(tickColor)
                    .frame(width: 2, height: width)
                Spacer(minLength: 0)
            }
        }
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
        GeometryReader { geo in
            let length = orientation == .vertical ? geo.size.height : geo.size.width
            let frac   = reductionFraction(reductionDB)
            let fillLen = frac * length

            if orientation == .vertical {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.meterTrack)
                    if fillLen > 0 {
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.meterAmber.opacity(0.8))
                                .frame(width: width, height: fillLen)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(width: width)
                .accessibilityHidden(true)
            } else {
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.meterTrack)
                    if fillLen > 0 {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Theme.meterAmber.opacity(0.8))
                                .frame(width: fillLen, height: width)
                        }
                    }
                }
                .frame(height: width)
                .accessibilityHidden(true)
            }
        }
    }
}
