import SwiftUI

// MARK: - Gain step buttons

private struct GainStepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - GainBlock

/// Gain as the headline control of the pane: a large readout flanked by the
/// step buttons, with the slider demoted underneath for coarse moves.
///
/// It was previously one more label-slider-value row, indistinguishable from
/// Pad, HPF frequency and the six compressor parameters — despite being the
/// one control that is touched daily and the one whose value has to be
/// readable from across the desk.
private struct GainBlock: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    private let stepDB: Float = 1.0
    private let gainRange: ClosedRange<Float> = -20...40

    var body: some View {
        VStack(spacing: 8) {
            Text("Gain")
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                GainStepButton(symbol: "minus", label: "Gain verringern") {
                    let next = max(gainRange.lowerBound, settings.gainDB - stepDB)
                    store.update(settings.deviceUID) { $0.gainDB = next }
                }

                VStack(spacing: 0) {
                    // Fixed width and a monospaced face: the readout changes
                    // while a step button is held, and a proportional font
                    // would shuffle both buttons sideways under the pointer.
                    Text(String(format: "%+.1f", settings.gainDB))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 108)
                    Text("dB")
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.bg))

                GainStepButton(symbol: "plus", label: "Gain erhöhen") {
                    let next = min(gainRange.upperBound, settings.gainDB + stepDB)
                    store.update(settings.deviceUID) { $0.gainDB = next }
                }

                Spacer(minLength: 0)
            }

            // Deliberately not full width. Stretched across the pane it sat
            // exactly where RØDE Connect puts a level meter, and a solid red
            // bar growing from the left edge reads as a level, not a control.
            // Kept to the width of the buttons above it so it reads as part of
            // the same group. Precision is unaffected: the ± buttons are the
            // exact route, this is the coarse one.
            Slider(
                value: bind(settings.gainDB, uid: settings.deviceUID, store: store,
                            keyPath: \.gainDB),
                in: gainRange
            )
            .tint(Theme.accent)
            .frame(maxWidth: 320)
            .accessibilityLabel(Text("Gain"))
            .accessibilityValue(Text(formatDB(settings.gainDB, decimals: 1)))
        }
    }
}

// MARK: - PadRow

private struct PadRow: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Pad")
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)

            Toggle(isOn: bind(settings.padEnabled, uid: settings.deviceUID, store: store,
                              keyPath: \.padEnabled)) {
                // Fixed width: "Off" and "-20 dB" are different lengths, and a
                // toggle that resizes when tapped drags the row with it.
                Text(settings.padEnabled ? "On" : "Off")
                    .frame(width: 24)
            }
            .toggleStyle(PillToggleStyle())
            .accessibilityLabel(Text("Pad"))
            .accessibilityValue(Text(settings.padEnabled ? formatDB(settings.padDB, decimals: 1) : "Off"))

            // Always present, disabled when the pad is off, so enabling it
            // cannot change the height or width of anything.
            Slider(
                value: bind(settings.padDB, uid: settings.deviceUID, store: store,
                            keyPath: \.padDB),
                in: -40...(-6)
            )
            .disabled(!settings.padEnabled)
            .tint(settings.padEnabled ? Theme.accent : Theme.textDisabled)
            .frame(maxWidth: .infinity)
            .opacity(settings.padEnabled ? 1 : 0.4)
            .accessibilityLabel(Text("Pad level"))
            .accessibilityValue(Text(formatDB(settings.padDB, decimals: 1)))

            ValueText(
                text: formatDB(settings.padDB, decimals: 1),
                colour: settings.padEnabled ? Theme.textPrimary : Theme.textDisabled)
        }
        .frame(height: 30)
    }
}

// MARK: - HPF row

private struct HPFRow: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("HPF")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 36, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(HPFMode.allCases) { mode in
                        Button {
                            store.update(settings.deviceUID) { $0.hpfMode = mode }
                        } label: {
                            Text(mode.label)
                                .font(Theme.labelFont)
                                .lineLimit(1)
                                .foregroundColor(settings.hpfMode == mode ? .black : Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                                        .fill(settings.hpfMode == mode ? Theme.accent : Theme.raised)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("HPF \(mode.label)"))
                        .accessibilityAddTraits(settings.hpfMode == mode ? .isSelected : [])
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 26)

            // The continuous-frequency row is always laid out, disabled unless
            // continuous mode is selected. Inserting it on demand would move
            // every effect panel below it each time the mode changed.
            HStack(spacing: 8) {
                Color.clear.frame(width: 36, height: 1)
                Text("Freq")
                    .font(Theme.labelFont)
                    .foregroundColor(isContinuous ? Theme.textSecondary : Theme.textDisabled)
                    .frame(width: 30, alignment: .leading)
                Slider(
                    value: bind(settings.hpfFrequency, uid: settings.deviceUID, store: store,
                                keyPath: \.hpfFrequency),
                    in: 20...500
                )
                .disabled(!isContinuous)
                .tint(isContinuous ? Theme.accent : Theme.textDisabled)
                .accessibilityLabel(Text("HPF Frequency"))
                .accessibilityValue(Text(formatHz(settings.hpfFrequency)))
                ValueText(
                    text: formatHz(settings.hpfFrequency),
                    width: 60,
                    colour: isContinuous ? Theme.textPrimary : Theme.textDisabled)
            }
            .frame(height: 26)
            .opacity(isContinuous ? 1 : 0.4)
        }
    }

    private var isContinuous: Bool { settings.hpfMode == .continuous }
}

// MARK: - MicDetailView

struct MicDetailView: View {
    let settings: ChannelSettings
    let connection: ChannelConnectionSource
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore

    @State private var selectedEffect: EffectKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    ConnectionIcon(source: connection, activeColour: Theme.accent, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.deviceName)
                            .font(Theme.titleFont)
                            .foregroundColor(Theme.textPrimary)
                        ConnectionLabel(source: connection)
                    }
                    Spacer()
                }
                .padding(.bottom, 4)

                // Input / output meters
                CardSection {
                    LiveInputMeterRow(source: meterSource)
                }

                // Gain controls
                CardSection {
                    VStack(spacing: 10) {
                        GainBlock(settings: settings, store: store)
                        Divider().background(Theme.border)
                        PadRow(settings: settings, store: store)
                        Divider().background(Theme.border)
                        HPFRow(settings: settings, store: store)
                    }
                }

                // Effects
                EffectSection(
                    settings: settings,
                    meterSource: meterSource,
                    store: store,
                    selected: $selectedEffect
                )
            }
            .padding(14)
        }
        .background(Theme.bg)
    }
}
