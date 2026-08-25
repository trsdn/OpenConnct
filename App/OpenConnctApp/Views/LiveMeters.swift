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
//   meters off (OPENCONNCT_METER_HZ=0), engine only ........... 0.7 %
//   same build, window shrunk to 760x552 ..................... 16.5 %
//
// Cost scaling with *window* area is the tell: each tick was dirtying far more
// than the meter. An @Published change is a graph transaction however small the
// observing view is, and SwiftUI offers no way to say "repaint these 8x148
// points and nothing else".
//
// So the bars moved to AppKit (see MeterNSView.swift) and the remaining text
// was slowed to ~5 Hz. Same three microphones, same 20 Hz:
//
//   AppKit meters, 943x980 window ............................. 6.2 %
//   AppKit meters, zoomed to 5120x1344 (7x the area) .......... 6.2 %
//   the same, each meter given its own backing layer .......... 5.6 %
//
// Flat in window area, which is the proof the dirty rectangles are now the
// meters themselves. The last line is `wantsLayer`: without a layer of its own
// a meter's repaint is merged into the enclosing one and the compositor still
// redraws more than the bar. For reference the engine — three microphones,
// full DSP chain, resampling, drift control and mixing — is the 0.7 % floor
// above, so what remains is still drawing, not audio.
//
// `OPENCONNCT_METER_HZ` remains, to measure and to switch meters off entirely.

/// One channel's live levels, published on two paths with different costs.
///
/// The bars go out through `subscribe`, straight to the AppKit meter views,
/// which never involve SwiftUI's update graph. What remains on `@Published` is
/// only what is genuinely slow-moving: the plain-language level verdicts and
/// the gain-reduction readouts. Those are rate limited to about 5 Hz and
/// rounded first.
///
/// The decibel readouts that used to sit beside every bar are gone. Rate
/// limiting made them cheap but it could not make them readable — a speech peak
/// really does move several decibels between syllables, so the figure jittered
/// no matter how it was damped, and the question it answered was one only
/// someone who already knew the target could use.
@MainActor
final class ChannelMeterSource: ObservableObject {
    /// Slow, rounded copy for the numeric readouts.
    @Published private(set) var meters = ChannelMeters()

    /// Latest values at the full meter rate. Deliberately not published:
    /// reading this from a SwiftUI body would not track changes, which is the
    /// point — anything needing full rate subscribes instead.
    private(set) var live = ChannelMeters()

    /// Subscribers, keyed by object identity so a view can replace or remove
    /// its own entry. The owner is held weakly and dead entries are pruned on
    /// publish: a view that is deallocated without unsubscribing (a window
    /// closing out from under it, say) must not keep this alive or accumulate.
    private struct Listener {
        weak var owner: AnyObject?
        let fn: (ChannelMeters) -> Void
    }

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var textTick = 0

    /// The loudest post-fader peak of the last second and a half, for the
    /// plain-language verdict.
    ///
    /// The verdict cannot use the instantaneous peak. The meter's own fall is
    /// 300 ms — about 29 dB per second — so a voice peaking correctly at
    /// -12 dBFS reads -24 dBFS a third of a second later, and the word beside
    /// the meter flips to "quiet" in every pause between sentences. The
    /// question it answers is "am I set right?", and the honest input to that
    /// is the loudest thing said recently.
    @Published private(set) var heldPeakDB: Float = -120
    private var peakHold = PeakHold()
    private var lastPublishTime: CFTimeInterval = 0

    /// Publish text this many meter ticks apart, so the numbers land near 5 Hz
    /// whatever the meter rate is.
    private static let textDivider: Int = {
        let hz = ParameterStore.meterHz
        guard hz > 0 else { return 1 }
        return max(1, Int((hz / 5).rounded()))
    }()

    func subscribe(_ owner: AnyObject, _ fn: @escaping (ChannelMeters) -> Void) {
        listeners[ObjectIdentifier(owner)] = Listener(owner: owner, fn: fn)
        fn(live)
    }

    func unsubscribe(_ owner: AnyObject) {
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    func publish(_ next: ChannelMeters) {
        live = next

        // Clamped for the same reason the meter views clamp: an app that was
        // suspended must not have the hold fall off a cliff on the first tick
        // after it wakes.
        let now = CACurrentMediaTime()
        let dt = lastPublishTime == 0 ? 0 : min(now - lastPublishTime, 0.25)
        lastPublishTime = now
        peakHold.advance(to: next.postFaderPeakDB, dt: dt)
        var dead: [ObjectIdentifier] = []
        for (key, listener) in listeners {
            guard listener.owner != nil else { dead.append(key); continue }
            listener.fn(next)
        }
        for key in dead { listeners.removeValue(forKey: key) }

        textTick += 1
        guard textTick >= Self.textDivider else { return }
        textTick = 0
        let rounded = next.roundedForDisplay()
        if rounded != meters { meters = rounded }
        // Rounded for the same reason everything else here is: the raw value
        // wanders in the third decimal and every change is a graph transaction.
        let heldRounded = (peakHold.db * 2).rounded() / 2
        if heldRounded != heldPeakDB { heldPeakDB = heldRounded }
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
///
/// Shows the post-fader level, so pulling the fader down pulls the bar down and
/// muting empties it. Anything else makes the fader look broken.
struct StripLevelMeter: View {
    @ObservedObject var source: ChannelMeterSource
    let muted: Bool

    var body: some View {
        LiveLevelMeter(
            source: source, tap: .postFader, orientation: .vertical,
            muted: muted, showsScale: true)
            .frame(width: 8)
            .accessibilityHidden(true)
    }
}

/// Colour for a plain-language level verdict. Matches the meter's own bands, so
/// the word and the picture can never disagree.
func verdictColour(_ verdict: MeterVerdict) -> Color {
    switch verdict {
    case .silent:   return Theme.textDisabled
    case .tooQuiet: return Theme.textSecondary
    case .good:     return Theme.meterGreen
    case .hot:      return Theme.meterAmber
    case .clipping: return Theme.meterRed
    }
}

/// Input and output levels in the detail sheet.
///
/// "OUT" is measured after the fader and mute, so every control the user can
/// reach — gain, the effects, the fader, the mute button — moves this bar. A
/// meter that ignores half the controls above it teaches the user to distrust
/// all of it.
///
/// No decibel figures. They were rate limited to 5 Hz and rounded to half a
/// decibel and they still read as noise, because a peak level genuinely does
/// move that much while someone is talking. What the user needs from this is
/// "is it in the right place", which is what the target band on the bar and
/// the word underneath already say.
struct LiveInputMeterRow: View {
    @ObservedObject var source: ChannelMeterSource

    var body: some View {
        let verdict = meterVerdict(peakDB: source.heldPeakDB)
        VStack(alignment: .leading, spacing: 4) {
            meterLine("IN", tap: .input, scale: false)
            meterLine("OUT", tap: .postFader, scale: true)
            HStack(spacing: 6) {
                Spacer().frame(width: 32)
                Text(verdict.text)
                    .font(Theme.captionFont)
                    .foregroundColor(verdictColour(verdict))
                Spacer(minLength: 0)
            }
            .frame(height: 12)
        }
    }

    @ViewBuilder
    private func meterLine(_ label: String, tap: MeterTap, scale: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, alignment: .leading)
            LiveLevelMeter(
                source: source, tap: tap, orientation: .horizontal,
                showsScale: scale)
                .frame(height: 12)
                .accessibilityHidden(true)
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
