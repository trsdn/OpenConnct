import SwiftUI

// MARK: - EffectKind
//
// The four processing stages, as one enumerable list rather than four
// near-identical view structs. The previous shape gave each effect its own
// panel with its own `@State expanded`, which meant four independent
// accordions: opening a second one pushed the first one's controls off the
// bottom, and nothing ever closed by itself. Selection now lives in one place
// so exactly one set of parameters is on screen at a time.

enum EffectKind: String, CaseIterable, Identifiable {
    case gate, compressor, exciter, bassEnhancer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gate:      return "Noise Gate"
        case .compressor: return "Compressor"
        case .exciter:   return "Exciter"
        case .bassEnhancer: return "Bass Enhancer"
        }
    }

    var symbol: String {
        switch self {
        case .gate:       return "waveform.path"
        case .compressor: return "arrow.down.right.and.arrow.up.left"
        case .exciter:    return "sparkles"
        case .bassEnhancer:  return "circle.bottomhalf.filled"
        }
    }

    var enabledKeyPath: WritableKeyPath<ChannelSettings, Bool> {
        switch self {
        case .gate:       return \.gateEnabled
        case .compressor: return \.compressorEnabled
        case .exciter:    return \.exciterEnabled
        case .bassEnhancer:  return \.bassEnhancerEnabled
        }
    }
}

// MARK: - EffectCircleButton

/// One effect as a round on/off button with its name beneath.
///
/// Two separate hit targets on purpose. The circle is large and does the
/// frequent thing (on/off); the small name button underneath does the rare
/// thing (show the parameters). Combining them was the old behaviour and it
/// meant switching an effect on also moved everything below it.
struct EffectCircleButton: View {
    let kind: EffectKind
    let isOn: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    private var ring: Color { isOn ? Theme.meterGreen : Theme.border }
    private var glyph: Color { isOn ? Theme.meterGreen : Theme.textDisabled }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onToggle) {
                ZStack {
                    Circle().fill(Theme.raised)
                    Circle().strokeBorder(ring, lineWidth: 2)
                    Image(systemName: kind.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(glyph)
                }
                .frame(width: 50, height: 50)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(kind.title))
            .accessibilityValue(Text(isOn ? "On" : "Off"))
            .accessibilityHint(Text(isOn ? "Turns the effect off" : "Turns the effect on"))

            Button(action: onSelect) {
                HStack(spacing: 3) {
                    Text(kind.title)
                        .font(Theme.captionFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(isSelected ? 180 : 0))
                }
                .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(isSelected ? Theme.raised : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isSelected
                ? "Hide \(kind.title) settings"
                : "Show \(kind.title) settings"))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - EffectSection

/// The row of four effect buttons. Parameters open in a popover anchored to
/// whichever button was asked for them.
///
/// They used to expand downward inside the pane. That is wrong for a fixed-size
/// surface: the parameters are six slider rows, the pane does not grow to make
/// room for them, so opening a set pushed the rest of the interface out through
/// the bottom and the user had to scroll to get back what was already on
/// screen. A popover costs the layout underneath it nothing, closes on click-
/// away or Escape without needing its own dismiss control, and puts the
/// parameters next to the button that owns them.
struct EffectSection: View {
    let settings: ChannelSettings
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore
    @Binding var selected: EffectKind?

    /// Muted covers being silenced by someone else's solo too, because the
    /// engine treats the two identically: both drive the fader to zero, and a
    /// channel at zero has its whole chain skipped.
    private var silenced: Bool { store.isEffectivelyMuted(settings) }

    var body: some View {
        CardSection {
            VStack(alignment: .leading, spacing: 6) {
                effectRow
                    // Dimmed, not disabled. The buttons still work — changing a
                    // setting on a muted channel is a normal thing to do while
                    // it is out of the mix, and it is in place by the time it
                    // comes back.
                    .opacity(silenced ? 0.45 : 1)
                notice
            }
        }
    }

    /// Fixed height whether or not the text is there. This pane is a sheet with
    /// a set size, and a line that appears and disappears would shift every
    /// control below it each time the channel is muted.
    private var notice: some View {
        Text(silenced ? "Muted — these are not running. Your settings are kept." : "")
            .font(Theme.captionFont)
            .foregroundColor(Theme.textSecondary)
            .frame(height: 13, alignment: .leading)
            .accessibilityHidden(!silenced)
    }

    private var effectRow: some View {
            HStack(alignment: .top, spacing: 4) {
                ForEach(EffectKind.allCases) { kind in
                    EffectCircleButton(
                        kind: kind,
                        isOn: settings[keyPath: kind.enabledKeyPath],
                        isSelected: selected == kind,
                        onToggle: {
                            store.update(settings.deviceUID) {
                                $0[keyPath: kind.enabledKeyPath].toggle()
                            }
                        },
                        onSelect: {
                            selected = (selected == kind) ? nil : kind
                        }
                    )
                    .popover(isPresented: isShowing(kind), arrowEdge: .bottom) {
                        EffectPopover(
                            kind: kind,
                            settings: settings,
                            meterSource: meterSource,
                            store: store)
                    }
                }
            }
    }

    /// A popover takes a boolean binding, but only one may be open at a time,
    /// so the four bindings are projections of the single selection. Writing
    /// `false` (a click-away or Escape) clears it; writing `true` cannot happen
    /// from the popover itself.
    private func isShowing(_ kind: EffectKind) -> Binding<Bool> {
        Binding(
            get: { selected == kind },
            set: { shown in
                if shown { selected = kind }
                else if selected == kind { selected = nil }
            }
        )
    }
}

// MARK: - EffectPopover

/// The parameters of one effect, with its name and on/off state at the top so
/// the popover is self-explanatory once detached from the button.
private struct EffectPopover: View {
    let kind: EffectKind
    let settings: ChannelSettings
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore

    private var isOn: Bool { settings[keyPath: kind.enabledKeyPath] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isOn ? Theme.meterGreen : Theme.textDisabled)
                Text(kind.title)
                    .font(Theme.titleFont)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 12)
                Toggle(isOn: bind(isOn, uid: settings.deviceUID, store: store,
                                  keyPath: kind.enabledKeyPath)) {
                    Text(isOn ? "On" : "Off").frame(width: 24)
                }
                .toggleStyle(PillToggleStyle())
                .accessibilityLabel(Text(kind.title))
            }

            Divider().background(Theme.border)

            EffectParameters(
                kind: kind,
                settings: settings,
                meterSource: meterSource,
                store: store)
        }
        .padding(14)
        // Wide enough that a slider still has usable travel once the label and
        // the value have taken their fixed columns, narrow enough that the
        // popover does not overhang the sheet it is anchored in.
        .frame(width: 360)
        .background(Theme.panel)
    }
}

// MARK: - EffectParameters

struct EffectParameters: View {
    let kind: EffectKind
    let settings: ChannelSettings
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore

    private var uid: String { settings.deviceUID }
    private var on: Bool { settings[keyPath: kind.enabledKeyPath] }

    var body: some View {
        VStack(spacing: 6) {
            switch kind {
            case .gate:       gate
            case .compressor: compressor
            case .exciter:    exciter
            case .bassEnhancer:  bassEnhancer
            }
        }
    }

    // MARK: Noise Gate

    @ViewBuilder private var gate: some View {
        LiveGRStrip(source: meterSource, stage: .gate)

        ParamSliderRow(
            "Threshold",
            value: bind(settings.gate.thresholdDB, uid: uid, store: store,
                        keyPath: \.gate.thresholdDB),
            range: -80...0,
            format: { formatDB($0) },
            enabled: on
        )
        ParamSliderRow(
            "Hysteresis",
            value: bind(settings.gate.hysteresisDB, uid: uid, store: store,
                        keyPath: \.gate.hysteresisDB),
            range: 0...20,
            format: { String(format: "%.1f dB", $0) },
            enabled: on
        )
        ParamSliderRow(
            "Range",
            value: bind(settings.gate.rangeDB, uid: uid, store: store,
                        keyPath: \.gate.rangeDB),
            range: -80...0,
            format: { $0 <= -79.5 ? "Mute" : formatDB($0) },
            enabled: on
        )
        ParamSliderRow(
            "Attack",
            value: bind(settings.gate.attackMS, uid: uid, store: store,
                        keyPath: \.gate.attackMS),
            range: 0.1...50,
            format: { formatMS($0) },
            enabled: on
        )
        ParamSliderRow(
            "Hold",
            value: bind(settings.gate.holdMS, uid: uid, store: store,
                        keyPath: \.gate.holdMS),
            range: 0...500,
            format: { formatMS($0) },
            enabled: on
        )
        ParamSliderRow(
            "Release",
            value: bind(settings.gate.releaseMS, uid: uid, store: store,
                        keyPath: \.gate.releaseMS),
            range: 5...2000,
            format: { formatMS($0) },
            enabled: on
        )
    }

    // MARK: Compressor

    @ViewBuilder private var compressor: some View {
        LiveGRStrip(source: meterSource, stage: .compressor)

        ParamSliderRow(
            "Threshold",
            value: bind(settings.compressor.thresholdDB, uid: uid, store: store,
                        keyPath: \.compressor.thresholdDB),
            range: -60...0,
            format: { formatDB($0) },
            enabled: on
        )
        ParamSliderRow(
            "Ratio",
            value: bind(settings.compressor.ratio, uid: uid, store: store,
                        keyPath: \.compressor.ratio),
            range: 1...20,
            format: { formatRatio($0) },
            enabled: on
        )
        ParamSliderRow(
            "Attack",
            value: bind(settings.compressor.attackMS, uid: uid, store: store,
                        keyPath: \.compressor.attackMS),
            range: 0.1...200,
            format: { formatMS($0) },
            enabled: on
        )
        ParamSliderRow(
            "Release",
            value: bind(settings.compressor.releaseMS, uid: uid, store: store,
                        keyPath: \.compressor.releaseMS),
            range: 10...2000,
            format: { formatMS($0) },
            enabled: on
        )
        ParamSliderRow(
            "Makeup",
            value: bind(settings.compressor.makeupDB, uid: uid, store: store,
                        keyPath: \.compressor.makeupDB),
            range: 0...24,
            format: { formatDB($0) },
            enabled: on
        )
        ParamSliderRow(
            "Knee",
            value: bind(settings.compressor.kneeDB, uid: uid, store: store,
                        keyPath: \.compressor.kneeDB),
            range: 0...12,
            format: { formatDB($0) },
            enabled: on
        )
    }

    // MARK: Exciter

    @ViewBuilder private var exciter: some View {
        ParamSliderRow(
            "Amount",
            value: bind(settings.exciter.amount, uid: uid, store: store,
                        keyPath: \.exciter.amount),
            range: 0...1,
            format: { String(format: "%.0f %%", $0 * 100) },
            enabled: on
        )
        ParamSliderRow(
            "Frequency",
            value: bind(settings.exciter.frequency, uid: uid, store: store,
                        keyPath: \.exciter.frequency),
            range: 1000...12000,
            format: { formatHz($0) },
            enabled: on
        )
        ParamSliderRow(
            "Drive",
            value: bind(settings.exciter.drive, uid: uid, store: store,
                        keyPath: \.exciter.drive),
            range: 0...1,
            format: { String(format: "%.0f %%", $0 * 100) },
            enabled: on
        )
    }

    // MARK: Bass Enhancer

    @ViewBuilder private var bassEnhancer: some View {
        ParamSliderRow(
            "Amount",
            value: bind(settings.bassEnhancer.amount, uid: uid, store: store,
                        keyPath: \.bassEnhancer.amount),
            range: 0...1,
            format: { String(format: "%.0f %%", $0 * 100) },
            enabled: on
        )
        ParamSliderRow(
            "Frequency",
            value: bind(settings.bassEnhancer.frequency, uid: uid, store: store,
                        keyPath: \.bassEnhancer.frequency),
            range: 40...400,
            format: { formatHz($0) },
            enabled: on
        )
        ParamSliderRow(
            "Drive",
            value: bind(settings.bassEnhancer.drive, uid: uid, store: store,
                        keyPath: \.bassEnhancer.drive),
            range: 0...1,
            format: { String(format: "%.0f %%", $0 * 100) },
            enabled: on
        )
    }
}
