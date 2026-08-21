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
//   * Turning the meters off (OPENCONNECT_METER_HZ=0) drops the app to 0.7%,
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
    case output
    case gateReduction
    case compressorReduction
}

// MARK: - The view

/// One meter bar. Subscribes to its channel directly and repaints only itself.
final class MeterNSView: NSView {
    var tap: MeterTap = .output
    var orientation: MeterOrientation = .vertical
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        subscribeIfVisible()
    }

    deinit {
        // ChannelMeterSource holds subscribers weakly by identity, so this is
        // belt and braces rather than strictly required.
        MainActor.assumeIsolated { source?.unsubscribe(self) }
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
        lastFillPx = fill
        lastPeakPx = peak
        needsDisplay = true
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

    func makeNSView(context: Context) -> MeterNSView {
        let v = MeterNSView()
        v.tap = tap
        v.orientation = orientation
        v.muted = muted
        v.source = source
        return v
    }

    func updateNSView(_ v: MeterNSView, context: Context) {
        v.tap = tap
        v.orientation = orientation
        v.muted = muted
        v.source = source
    }
}
