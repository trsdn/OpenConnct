import SwiftUI

// MARK: - EffectPanel header row

private struct EffectHeader: View {
    let title: String
    let isEnabled: Bool
    let isExpanded: Bool
    let onToggleEnabled: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Enable toggle (pill)
            Button(action: onToggleEnabled) {
                Circle()
                    .fill(isEnabled ? Theme.accent : Theme.raised)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().strokeBorder(
                            isEnabled ? Theme.accent : Theme.textDisabled,
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isEnabled ? "On" : "Off"))
            .accessibilityHint(Text(isEnabled ? "Tap to disable" : "Tap to enable"))

            Text(title)
                .font(Theme.titleFont)
                .foregroundColor(isEnabled ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Disclosure chevron
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded ? "Collapse \(title)" : "Expand \(title)"))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
    }
}

// MARK: - Gain reduction strip

private struct GRStrip: View {
    let reductionDB: Float

    var body: some View {
        HStack(spacing: 4) {
            Text("GR")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 20, alignment: .leading)
            GainReductionMeterView(reductionDB: reductionDB, orientation: .horizontal, width: 8)
            Text(reductionDB > 0.1 ? String(format: "−%.1f dB", reductionDB) : "—")
                .font(Theme.valueFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
        }
        .frame(height: 12)
    }
}

// MARK: - GatePanel

struct GatePanel: View {
    let settings: ChannelSettings
    let meters: ChannelMeters
    @ObservedObject var store: ParameterStore
    @State private var expanded = false

    private var uid: String { settings.deviceUID }
    private var on: Bool { settings.gateEnabled }

    var body: some View {
        CardSection {
            VStack(spacing: 8) {
                EffectHeader(
                    title: "Noise Gate",
                    isEnabled: on,
                    isExpanded: expanded,
                    onToggleEnabled: { store.update(uid) { $0.gateEnabled.toggle() } },
                    onToggleExpand: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                )

                if expanded {
                    VStack(spacing: 6) {
                        GRStrip(reductionDB: -meters.gateReductionDB)

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
                }
            }
        }
    }
}

// MARK: - CompressorPanel

struct CompressorPanel: View {
    let settings: ChannelSettings
    let meters: ChannelMeters
    @ObservedObject var store: ParameterStore
    @State private var expanded = false

    private var uid: String { settings.deviceUID }
    private var on: Bool { settings.compressorEnabled }

    var body: some View {
        CardSection {
            VStack(spacing: 8) {
                EffectHeader(
                    title: "Compressor",
                    isEnabled: on,
                    isExpanded: expanded,
                    onToggleEnabled: { store.update(uid) { $0.compressorEnabled.toggle() } },
                    onToggleExpand: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                )

                if expanded {
                    VStack(spacing: 6) {
                        GRStrip(reductionDB: -meters.compressorReductionDB)

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
                }
            }
        }
    }
}

// MARK: - ExciterPanel

struct ExciterPanel: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore
    @State private var expanded = false

    private var uid: String { settings.deviceUID }
    private var on: Bool { settings.exciterEnabled }

    var body: some View {
        CardSection {
            VStack(spacing: 8) {
                EffectHeader(
                    title: "Aural Exciter",
                    isEnabled: on,
                    isExpanded: expanded,
                    onToggleEnabled: { store.update(uid) { $0.exciterEnabled.toggle() } },
                    onToggleExpand: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                )

                if expanded {
                    VStack(spacing: 6) {
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
                }
            }
        }
    }
}

// MARK: - BigBottomPanel

struct BigBottomPanel: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore
    @State private var expanded = false

    private var uid: String { settings.deviceUID }
    private var on: Bool { settings.bigBottomEnabled }

    var body: some View {
        CardSection {
            VStack(spacing: 8) {
                EffectHeader(
                    title: "Big Bottom",
                    isEnabled: on,
                    isExpanded: expanded,
                    onToggleEnabled: { store.update(uid) { $0.bigBottomEnabled.toggle() } },
                    onToggleExpand: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                )

                if expanded {
                    VStack(spacing: 6) {
                        ParamSliderRow(
                            "Amount",
                            value: bind(settings.bigBottom.amount, uid: uid, store: store,
                                        keyPath: \.bigBottom.amount),
                            range: 0...1,
                            format: { String(format: "%.0f %%", $0 * 100) },
                            enabled: on
                        )
                        ParamSliderRow(
                            "Frequency",
                            value: bind(settings.bigBottom.frequency, uid: uid, store: store,
                                        keyPath: \.bigBottom.frequency),
                            range: 40...400,
                            format: { formatHz($0) },
                            enabled: on
                        )
                        ParamSliderRow(
                            "Drive",
                            value: bind(settings.bigBottom.drive, uid: uid, store: store,
                                        keyPath: \.bigBottom.drive),
                            range: 0...1,
                            format: { String(format: "%.0f %%", $0 * 100) },
                            enabled: on
                        )
                    }
                }
            }
        }
    }
}
