import SwiftUI

// MARK: - Gain step buttons

private struct GainStepButton: View {
    let symbol: String
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

            GainStepButton(symbol: "minus") {
                let next = max(gainRange.lowerBound, settings.gainDB - stepDB)
                store.update(settings.deviceUID) { $0.gainDB = next }
            }

            Text(formatDB(settings.gainDB, decimals: 1))
                .font(Theme.valueFont)
                .foregroundColor(Theme.textPrimary)
                .frame(width: 64, alignment: .center)
                .monospacedDigit()

            GainStepButton(symbol: "plus") {
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
                Text(settings.padEnabled ? formatDB(settings.padDB, decimals: 0) : "Off")
            }
            .toggleStyle(PillToggleStyle())

            if settings.padEnabled {
                Slider(
                    value: bind(settings.padDB, uid: settings.deviceUID, store: store,
                                keyPath: \.padDB),
                    in: -40...(-6)
                )
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)

                Text(formatDB(settings.padDB, decimals: 1))
                    .font(Theme.valueFont)
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 56, alignment: .trailing)
                    .monospacedDigit()
            } else {
                Spacer()
            }
        }
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
                                .foregroundColor(settings.hpfMode == mode ? .black : Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                                        .fill(settings.hpfMode == mode ? Theme.accent : Theme.raised)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }

            if settings.hpfMode == .continuous {
                HStack(spacing: 8) {
                    Text("")
                        .frame(width: 36)
                    Text("Freq")
                        .font(Theme.labelFont)
                        .foregroundColor(Theme.textSecondary)
                    Slider(
                        value: bind(settings.hpfFrequency, uid: settings.deviceUID, store: store,
                                    keyPath: \.hpfFrequency),
                        in: 20...500
                    )
                    .tint(Theme.accent)
                    Text(formatHz(settings.hpfFrequency))
                        .font(Theme.valueFont)
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - InputMeterRow

private struct InputMeterRow: View {
    let meters: ChannelMeters

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("IN")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, alignment: .leading)
                LevelMeterView(
                    rmsDB: meters.inputRMSDB,
                    peakDB: meters.inputPeakDB,
                    orientation: .horizontal,
                    width: 12
                )
                Text(meters.inputPeakDB > -120
                     ? String(format: "%.1f", meters.inputPeakDB)
                     : "—")
                    .font(Theme.valueFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                    .monospacedDigit()
            }
            .frame(height: 14)

            HStack(spacing: 4) {
                Text("OUT")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, alignment: .leading)
                LevelMeterView(
                    rmsDB: meters.outputRMSDB,
                    peakDB: meters.outputPeakDB,
                    orientation: .horizontal,
                    width: 12
                )
                Text(meters.outputPeakDB > -120
                     ? String(format: "%.1f", meters.outputPeakDB)
                     : "—")
                    .font(Theme.valueFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                    .monospacedDigit()
            }
            .frame(height: 14)
        }
    }
}

// MARK: - MicDetailView

struct MicDetailView: View {
    let settings: ChannelSettings
    let meters: ChannelMeters
    @ObservedObject var store: ParameterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: meters.connected ? "mic.fill" : "mic.slash.fill")
                        .foregroundColor(meters.connected ? Theme.accent : Theme.textDisabled)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.deviceName)
                            .font(Theme.titleFont)
                            .foregroundColor(Theme.textPrimary)
                        Text(meters.connected ? "Connected" : "Disconnected")
                            .font(Theme.captionFont)
                            .foregroundColor(meters.connected ? Theme.meterGreen : Theme.textDisabled)
                    }
                    Spacer()
                }
                .padding(.bottom, 4)

                // Input / output meters
                CardSection {
                    InputMeterRow(meters: meters)
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
                GatePanel(settings: settings, meters: meters, store: store)
                CompressorPanel(settings: settings, meters: meters, store: store)
                ExciterPanel(settings: settings, store: store)
                BigBottomPanel(settings: settings, store: store)
            }
            .padding(14)
        }
        .background(Theme.bg)
    }
}
