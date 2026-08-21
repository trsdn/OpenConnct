import SwiftUI

// Where the meter cost actually is, measured rather than assumed. All four
// arrangements below were built and measured on the same machine with two live
// microphones at 30 Hz, window open:
//
//   published from ParameterStore, whole tree observing ....... 26.0 %
//   one observable per channel, only meter leaves observing ... 12.5 %   <- this
//   one shared observable holding every channel's levels ...... 15.8 %
//   a TimelineView per meter, pulling instead of pushing ...... 18.5 %
//
// The per-channel arrangement won, so that is what is here. Note that the
// engine itself — two microphones, full DSP chain, resampling, drift control
// and mixing — measures 0.5% on the same machine, so essentially all of this is
// the cost of drawing, not of processing audio. `OPENCONNECT_METER_HZ` exists
// to measure and control it; the cost is linear in the rate.

/// One channel's live levels. Observed only by meter leaf views.
@MainActor
final class ChannelMeterSource: ObservableObject {
    @Published private(set) var meters = ChannelMeters()

    func publish(_ next: ChannelMeters) {
        if next != meters { meters = next }
    }
}

struct ConnectionIcon: View {
    @ObservedObject var source: ChannelConnectionSource
    var activeColour: Color = Theme.textSecondary
    var size: CGFloat = 14

    var body: some View {
        let connected = source.connected
        Image(systemName: connected ? "mic.fill" : "mic.slash.fill")
            .foregroundColor(connected ? activeColour : Theme.textDisabled)
            .font(.system(size: size))
    }
}

struct ConnectionLabel: View {
    @ObservedObject var source: ChannelConnectionSource

    var body: some View {
        let connected = source.connected
        Text(connected ? "Connected" : "Disconnected")
            .font(Theme.captionFont)
            .foregroundColor(connected ? Theme.meterGreen : Theme.textDisabled)
    }
}

/// The vertical meter beside a channel strip's fader.
struct StripLevelMeter: View {
    @ObservedObject var source: ChannelMeterSource
    let muted: Bool

    var body: some View {
        let m = source.meters
        LevelMeterView(
            rmsDB: muted ? -120 : m.outputRMSDB,
            peakDB: muted ? -120 : m.outputPeakDB,
            orientation: .vertical,
            width: 8
        )
        .frame(width: 8)
    }
}

/// Input and output levels in the detail pane.
struct LiveInputMeterRow: View {
    @ObservedObject var source: ChannelMeterSource

    var body: some View {
        let m = source.meters
        VStack(spacing: 4) {
            meterLine("IN", rms: m.inputRMSDB, peak: m.inputPeakDB)
            meterLine("OUT", rms: m.outputRMSDB, peak: m.outputPeakDB)
        }
    }

    @ViewBuilder
    private func meterLine(_ label: String, rms: Float, peak: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, alignment: .leading)
            LevelMeterView(rmsDB: rms, peakDB: peak, orientation: .horizontal, width: 12)
                .frame(height: 12)
            ValueText(
                text: peak > -120 ? String(format: "%.1f", peak) : "—",
                width: 44,
                colour: Theme.textSecondary)
        }
        .frame(height: 16)
    }
}

/// Gain-reduction readout inside the gate and compressor panels.
struct LiveGRStrip: View {
    enum Stage { case gate, compressor }

    @ObservedObject var source: ChannelMeterSource
    let stage: Stage

    var body: some View {
        let m = source.meters
        strip(stage == .gate ? -m.gateReductionDB : -m.compressorReductionDB)
    }

    @ViewBuilder
    private func strip(_ reductionDB: Float) -> some View {
        HStack(spacing: 6) {
            Text("GR")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, alignment: .leading)
            GainReductionMeterView(reductionDB: reductionDB, orientation: .horizontal, width: 8)
                .frame(height: 8)
            ValueText(
                text: reductionDB > 0.1 ? String(format: "−%.1f dB", reductionDB) : "—",
                colour: Theme.textSecondary)
        }
        .frame(height: 22)
    }
}
