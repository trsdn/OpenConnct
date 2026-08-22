import AppKit
import SwiftUI

// Why the meters are AppKit views and not SwiftUI ones.
//
// The SwiftUI meters were correct and narrowly scoped — one small observable
// per channel, `Canvas` leaves, no shared state — and they still cost 22% of a
// core with three microphones at 20 Hz in a 943x980 window. Measured on the
// same machine and the same build, the audio engine costs 0.7%. So the meters
// were 97% of the application's CPU.
//
// Two things were established by measurement before this rewrite:
//
//   * Turning the meters off (OPENCONNCT_METER_HZ=0) drops the app to 0.7%,
//     so the cost is entirely in the meter path.
//   * Shrinking the window from 943x980 to 760x552 dropped it from 22% to
//     16.5%. Cost therefore scales with *window* area, not meter area, which
//     means every meter tick was dirtying far more than the meter.
//
// The remaining cost is SwiftUI re-evaluating and re-compositing on every
// tick. An `@Published` change is a graph transaction no matter how small the
// observing view is, and there is no way to ask SwiftUI for "redraw these 8x148
// points and nothing else".
//
// AppKit does exactly that. Each meter is one `NSView` that subscribes to its
// channel's meter source directly, converts the level to a pixel length, and
// marks itself dirty only when that length actually changes. SwiftUI's graph is
// never involved: `updateNSView` runs when mute or orientation changes, not
// when a level does.
//
// Two further savings fall out of this for free:
//   * A meter inside a collapsed effect panel is not in the view hierarchy, so
//     `viewDidMoveToWindow` never subscribes it and it costs nothing.
//   * Sub-pixel level jitter in a quiet room does not redraw anything.

// MARK: - Which value a meter shows

enum MeterTap {
    case input
    /// After gain and the DSP chain, but before the fader and mute.
    case output
    /// After the fader and mute — what the channel actually sends to the mix.
    case postFader
    case gateReduction
    case compressorReduction
}

// MARK: - The view

/// One meter bar. Subscribes to its channel directly and repaints only itself.
final class MeterNSView: NSView {
    var tap: MeterTap = .postFader
    var orientation: MeterOrientation = .vertical
    /// Draws the target band and the dB ticks into the track. Off for the small
    /// horizontal bars, where there is no room for either to read as anything
    /// but noise.
    var showsScale: Bool = false {
        didSet { if showsScale != oldValue { needsDisplay = true } }
    }
    var muted: Bool = false {
        didSet { if muted != oldValue { refresh(force: true) } }
    }

    var source: ChannelMeterSource? {
        didSet {
            guard source !== oldValue else { return }
            oldValue?.unsubscribe(self)
            subscribeIfVisible()
        }
    }

    private var rmsDB: Float = -120
    private var peakDB: Float = -120
    private var reductionDB: Float = 0

    // Last values converted to pixels. A tick that does not move any bar by a
    // whole pixel is discarded without touching the display.
    private var lastFillPx: CGFloat = -1
    private var lastPeakPx: CGFloat = -1

    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Give the meter its own backing layer. Without one the repaint is
        // merged into the enclosing layer and the compositor redraws far more
        // than the bar; with one, only this layer is re-rendered and blended.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        subscribeIfVisible()
    }

    private func subscribeIfVisible() {
        guard let source else { return }
        if window == nil {
            source.unsubscribe(self)
        } else {
            source.subscribe(self) { [weak self] meters in
                self?.apply(meters)
            }
        }
    }

    private func apply(_ m: ChannelMeters) {
        switch tap {
        case .input:
            rmsDB = m.inputRMSDB; peakDB = m.inputPeakDB
        case .output:
            rmsDB = m.outputRMSDB; peakDB = m.outputPeakDB
        case .postFader:
            rmsDB = m.postFaderRMSDB; peakDB = m.postFaderPeakDB
        case .gateReduction:
            reductionDB = -m.gateReductionDB
        case .compressorReduction:
            reductionDB = -m.compressorReductionDB
        }
        refresh(force: false)
    }

    private var isReductionMeter: Bool {
        tap == .gateReduction || tap == .compressorReduction
    }

    private var barLength: CGFloat {
        orientation == .vertical ? bounds.height : bounds.width
    }

    private func refresh(force: Bool) {
        let length = barLength
        guard length > 0 else { return }

        let fill: CGFloat
        let peak: CGFloat
        if isReductionMeter {
            fill = (reductionFraction(reductionDB) * length).rounded()
            peak = 0
        } else {
            let level = muted ? Float(-120) : rmsDB
            let held  = muted ? Float(-120) : peakDB
            fill = (meterPosition(level) * length).rounded()
            peak = (meterPosition(held) * length).rounded()
        }

        guard force || fill != lastFillPx || peak != lastPeakPx else { return }

        // Repaint only the span that actually moved. `needsDisplay = true` costs
        // the whole bar, and the whole bar is not the same size everywhere: a
        // strip meter is 8x120, but the IN/OUT bars in the detail sheet are over
        // 400pt wide. A wide bar is worse twice over — more pixels per repaint,
        // and, because a decibel maps to more pixels, a repaint far more often.
        // Measured before the change: opening the detail sheet took the app from
        // ~7% of a core to ~17%, with the sheet itself costing nothing when
        // meters were switched off. So the length of the bar was the cost, and
        // dirtying by span removes that dependency the same way giving each
        // meter its own layer removed the dependency on window size.
        //
        // `draw(_:)` repaints from scratch and never reads what was there
        // before, so it is correct under any clip.
        if force || lastFillPx < 0 || lastPeakPx < 0 {
            needsDisplay = true
        } else {
            var dirty = span(from: lastFillPx, to: fill)
            if !isReductionMeter {
                dirty = dirty.union(span(from: lastPeakPx, to: peak + 2))
            }
            setNeedsDisplay(dirty)
        }
        lastFillPx = fill
        lastPeakPx = peak
    }

    /// The rectangle covering everything between two fill distances, in view
    /// coordinates. Reduction meters grow from the far end, so their distances
    /// have to be mirrored before they mean anything as coordinates.
    private func span(from: CGFloat, to: CGFloat) -> NSRect {
        let length = barLength
        var lo = min(from, to)
        var hi = max(from, to)
        if isReductionMeter {
            (lo, hi) = (length - hi, length - lo)
        }
        lo = max(0, lo - 2)
        hi = min(length, hi + 2)
        guard hi > lo else { return .null }
        return orientation == .vertical
            ? NSRect(x: 0, y: lo, width: bounds.width, height: hi - lo)
            : NSRect(x: lo, y: 0, width: hi - lo, height: bounds.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Pixel positions were computed against the old size.
        lastFillPx = -1
        lastPeakPx = -1
        needsDisplay = true
    }

    // MARK: Drawing
    //
    // Deliberately a straight port of the previous `Canvas` drawing so the
    // meters look identical; only the host changed. AppKit's default coordinate
    // system already has its origin at the bottom left, so the vertical case no
    // longer needs the flip the SwiftUI version did.

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        ctx.setFillColor(NSColor(Theme.meterTrack).cgColor)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()

        let vertical = orientation == .vertical
        let length = vertical ? size.height : size.width
        let thickness = vertical ? size.width : size.height

        if showsScale && !isReductionMeter {
            drawScale(ctx, length: length, thickness: thickness, vertical: vertical)
        }

        if isReductionMeter {
            let fillLen = reductionFraction(reductionDB) * length
            guard fillLen > 0 else { return }
            // Gain reduction reads as the bar eating into the track: downward
            // from the top when vertical, leftward from the right when not.
            let rect = vertical
                ? CGRect(x: 0, y: length - fillLen, width: size.width, height: fillLen)
                : CGRect(x: length - fillLen, y: 0, width: fillLen, height: size.height)
            ctx.setFillColor(NSColor(Theme.meterAmber.opacity(0.8)).cgColor)
            ctx.fill(rect)
            return
        }

        let level = muted ? Float(-120) : rmsDB
        let held  = muted ? Float(-120) : peakDB

        let rmsLen = meterPosition(level) * length
        let amberPos = meterPosition(meterAmberDB) * length
        let redPos = meterPosition(meterRedDB) * length

        segment(ctx, from: 0, to: min(rmsLen, amberPos),
                colour: Theme.meterGreen, vertical: vertical, thickness: thickness)
        segment(ctx, from: amberPos, to: min(rmsLen, redPos),
                colour: Theme.meterAmber, vertical: vertical, thickness: thickness)
        segment(ctx, from: redPos, to: rmsLen,
                colour: Theme.meterRed, vertical: vertical, thickness: thickness)

        let peakPos = meterPosition(held) * length
        let tickColour = held > meterRedDB ? Theme.meterRed
                       : held > meterAmberDB ? Theme.meterAmber
                       : Theme.meterGreen
        segment(ctx, from: peakPos, to: peakPos + 2,
                colour: tickColour, vertical: vertical, thickness: thickness)
    }

    /// Fills the band between two distances measured from the meter's origin —
    /// the bottom edge when vertical, the leading edge when horizontal.
    private func segment(
        _ ctx: CGContext, from: CGFloat, to: CGFloat, colour: Color,
        vertical: Bool, thickness: CGFloat
    ) {
        let length = barLength
        let lo = max(0, min(from, length))
        let hi = max(0, min(to, length))
        guard hi > lo else { return }

        let rect = vertical
            ? CGRect(x: 0, y: lo, width: thickness, height: hi - lo)
            : CGRect(x: lo, y: 0, width: hi - lo, height: thickness)
        ctx.setFillColor(NSColor(colour).cgColor)
        ctx.fill(rect)
    }

    /// Draws the target band and the dB ticks into the empty track, underneath
    /// the level bar.
    ///
    /// This is the answer to "where is it supposed to be?". Without it the meter
    /// shows a quantity with no reference, which is why a user can watch it for
    /// weeks and still not know whether they are aiming right.
    ///
    /// The band is a thin rail along one edge, not a filled block. Filling the
    /// full thickness worked on an 8pt vertical bar and failed badly on a wide
    /// horizontal one: a green rectangle a third of the meter long reads as
    /// *level*, which is precisely the misreading these marks exist to prevent.
    /// A rail cannot be mistaken for a bar. It still sits under the level, so a
    /// correctly set signal covers it — guidance while you set up, gone once you
    /// are there.
    private func drawScale(
        _ ctx: CGContext, length: CGFloat, thickness: CGFloat, vertical: Bool
    ) {
        let lowPos  = meterPosition(meterTargetLowDB) * length
        let highPos = meterPosition(meterTargetHighDB) * length
        let rail = max(2, min(3, thickness / 3)).rounded()
        if highPos > lowPos {
            ctx.setFillColor(NSColor(Theme.meterGreen.opacity(0.55)).cgColor)
            ctx.fill(vertical
                ? CGRect(x: 0, y: lowPos, width: rail, height: highPos - lowPos)
                : CGRect(x: lowPos, y: 0, width: highPos - lowPos, height: rail))
        }

        // One tick per labelled level, spanning the full thickness so it reads
        // as a scale mark rather than as part of the rail. Rounded to whole
        // pixels so they stay crisp and identical to each other at any size.
        ctx.setFillColor(NSColor(Color(white: 1, opacity: 0.16)).cgColor)
        for db in meterTickDB {
            let pos = (meterPosition(db) * length).rounded()
            guard pos > 0, pos < length else { continue }
            ctx.fill(vertical
                ? CGRect(x: 0, y: pos, width: thickness, height: 1)
                : CGRect(x: pos, y: 0, width: 1, height: thickness))
        }
    }

    // Meters carry no information a screen reader can use, and announcing a
    // level twenty times a second would be actively hostile.
    override func accessibilityIsIgnored() -> Bool { true }
}

// MARK: - SwiftUI wrappers

/// Level meter driven straight from the channel source, bypassing SwiftUI's
/// update graph. `muted` is the only thing SwiftUI still drives, and it changes
/// when the user clicks, not twenty times a second.
struct LiveLevelMeter: NSViewRepresentable {
    let source: ChannelMeterSource
    let tap: MeterTap
    let orientation: MeterOrientation
    var muted: Bool = false
    var showsScale: Bool = false

    func makeNSView(context: Context) -> MeterNSView {
        let v = MeterNSView()
        v.tap = tap
        v.orientation = orientation
        v.muted = muted
        v.showsScale = showsScale
        v.source = source
        return v
    }

    func updateNSView(_ v: MeterNSView, context: Context) {
        v.tap = tap
        v.orientation = orientation
        v.muted = muted
        v.showsScale = showsScale
        v.source = source
    }
}
