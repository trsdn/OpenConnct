import SwiftUI

// Where the meter cost actually is, measured rather than assumed. Every line
// below was built and measured on the same machine, window open.
//
// First round, two live microphones at 30 Hz, all four arrangements in SwiftUI:
//
//   published from ParameterStore, whole tree observing ....... 26.0 %
//   one observable per channel, only meter leaves observing ... 12.5 %
//   one shared observable holding every channel's levels ...... 15.8 %
//   a TimelineView per meter, pulling instead of pushing ...... 18.5 %
//
// The per-channel arrangement won and was kept. It was still wrong. With three
// microphones at 20 Hz in a 943x980 window it cost 22 %, and two further
// measurements showed why:
//
//   meters off (OPENCONNECT_METER_HZ=0), engine only ........... 0.7 %
//   same build, window shrunk to 760x552 ..................... 16.5 %
//
// Cost scaling with *window* area is the tell: each tick was dirtying far more
// than the meter. An @Published change is a graph transaction however small the
// observing view is, and SwiftUI offers no way to say "repaint these 8x148
// points and nothing else".
//
// So the bars moved to AppKit (see MeterNSView.swift) and the numbers were
// slowed to ~5 Hz and rounded to 0.5 dB. Same three microphones, same 20 Hz:
//
//   AppKit meters, 943x980 window ............................. 6.2 %
//   AppKit meters, zoomed to 5120x1344 (7x the area) .......... 6.2 %
//
// Flat in window area, which is the proof the dirty rectangles are now the
// meters themselves. For reference the engine — three microphones, full DSP
// chain, resampling, drift control and mixing — is the 0.7 % floor above.
//
// `OPENCONNECT_METER_HZ` remains, to measure and to switch meters off entirely.

/// One channel's live levels, published on two paths with different costs.
///
/// The bars go out through `subscribe`, straight to the AppKit meter views,
/// which never involve SwiftUI's update graph. The numeric readouts stay on
/// `@Published` because they are cheap Text views — but they are rate limited
/// to about 5 Hz and rounded to 0.5 dB first. A number changing twenty times a
/// second is unreadable anyway; the user's complaint was that it "jumps the
/// whole time", and they were right.
@MainActor
final class ChannelMeterSource: ObservableObject {
    /// Slow, rounded copy for the numeric readouts.
    @Published private(set) var meters = ChannelMeters()

    /// Latest values at the full meter rate. Deliberately not published:
    /// reading this from a SwiftUI body would not track changes, which is the
    /// point — anything needing full rate subscribes instead.
    private(set) var live = ChannelMeters()

    private var listeners: [ObjectIdentifier: (ChannelMeters) -> Void] = [:]
    private var textTick = 0

    /// Publish text this many meter ticks apart, so the numbers land near 5 Hz
    /// whatever the meter rate is.
    private static let textDivider: Int = {
        let hz = ParameterStore.meterHz
        guard hz > 0 else { return 1 }
        return max(1, Int((hz / 5).rounded()))
    }()

    func subscribe(_ owner: AnyObject, _ fn: @escaping (ChannelMeters) -> Void) {
        listeners[ObjectIdentifier(owner)] = fn
        fn(live)
    }

    func unsubscribe(_ owner: AnyObject) {
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    func publish(_ next: ChannelMeters) {
        live = next
        for fn in listeners.values { fn(next) }

        textTick += 1
        guard textTick >= Self.textDivider else { return }
        textTick = 0
        let rounded = next.roundedForDisplay()
        if rounded != meters { meters = rounded }
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
        LiveLevelMeter(source: source, tap: .output, orientation: .vertical, muted: muted)
            .frame(width: 8)
            .accessibilityHidden(true)
    }
}

/// Input and output levels in the detail pane.
struct LiveInputMeterRow: View {
    @ObservedObject var source: ChannelMeterSource

    var body: some View {
        let m = source.meters
        VStack(spacing: 4) {
            meterLine("IN", tap: .input, peak: m.inputPeakDB)
            meterLine("OUT", tap: .output, peak: m.outputPeakDB)
        }
    }

    @ViewBuilder
    private func meterLine(_ label: String, tap: MeterTap, peak: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, alignment: .leading)
            LiveLevelMeter(source: source, tap: tap, orientation: .horizontal)
                .frame(height: 12)
                .accessibilityHidden(true)
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
        let tap: MeterTap = stage == .gate ? .gateReduction : .compressorReduction
        HStack(spacing: 6) {
            Text("GR")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, alignment: .leading)
            LiveLevelMeter(source: source, tap: tap, orientation: .horizontal)
                .frame(height: 8)
                .accessibilityHidden(true)
            ValueText(
                text: reductionDB > 0.1 ? String(format: "−%.1f dB", reductionDB) : "—",
                colour: Theme.textSecondary)
        }
        .frame(height: 22)
    }
}
