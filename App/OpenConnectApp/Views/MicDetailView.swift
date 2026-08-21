import SwiftUI

// MARK: - Gain step buttons

private struct GainStepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - GainRow

private struct GainRow: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    private let stepDB: Float = 1.0
    private let gainRange: ClosedRange<Float> = -20...40

    var body: some View {
        HStack(spacing: 8) {
            Text("Gain")
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)

            GainStepButton(symbol: "minus", label: "Decrease gain") {
                let next = max(gainRange.lowerBound, settings.gainDB - stepDB)
                store.update(settings.deviceUID) { $0.gainDB = next }
            }

            ValueText(text: formatDB(settings.gainDB, decimals: 1), width: 64, alignment: .center)

            GainStepButton(symbol: "plus", label: "Increase gain") {
                let next = min(gainRange.upperBound, settings.gainDB + stepDB)
                store.update(settings.deviceUID) { $0.gainDB = next }
            }

            Slider(
                value: bind(settings.gainDB, uid: settings.deviceUID, store: store,
                            keyPath: \.gainDB),
                in: gainRange
            )
            .tint(Theme.accent)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Gain"))
            .accessibilityValue(Text(formatDB(settings.gainDB, decimals: 1)))
        }
        .frame(height: 30)
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
                    VStack(spacing: 8) {
                        GainRow(settings: settings, store: store)
                        Divider().background(Theme.border)
                        PadRow(settings: settings, store: store)
                        Divider().background(Theme.border)
                        HPFRow(settings: settings, store: store)
                    }
                }

                // Effect panels
                GatePanel(settings: settings, meterSource: meterSource, store: store)
                CompressorPanel(settings: settings, meterSource: meterSource, store: store)
                ExciterPanel(settings: settings, store: store)
                BigBottomPanel(settings: settings, store: store)
            }
            .padding(14)
        }
        .background(Theme.bg)
    }
}
