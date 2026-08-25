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
    let onCalibrate: () -> Void

    private let stepDB: Float = 1.0

    /// The usable total. With a microphone that has its own preamp the number
    /// now covers that preamp as well as the DSP trim, so the ceiling has to
    /// leave room above what the device alone can reach — otherwise adopting a
    /// device already near its maximum would land outside the slider.
    ///
    /// Defined on the store so the guided calibration clamps to exactly the
    /// same range; two copies would eventually disagree.
    private var gainRange: ClosedRange<Float> { store.gainRange(for: settings.deviceUID) }

    private var processing: ChannelProcessingMap {
        ChannelProcessingMap.resolve(
            hardwareGainRange: store.hardwareGainRanges[settings.deviceUID],
            hardwareGainEnabled: settings.hardwareGainEnabled)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Gain")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                ProcessingBadge(location: processing.gain)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                GainStepButton(symbol: "minus", label: "Decrease gain") {
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

                GainStepButton(symbol: "plus", label: "Increase gain") {
                    let next = min(gainRange.upperBound, settings.gainDB + stepDB)
                    store.update(settings.deviceUID) { $0.gainDB = next }
                }

                Spacer(minLength: 0)
            }

            // Deliberately not full width. Stretched across the pane it sat
            // exactly where a level meter would go, and a solid red bar growing
            // from the left edge reads as a level, not a control. Kept to the
            // width of the buttons above it so it reads as part of the same
            // group. Precision is unaffected: the ± buttons are the exact
            // route, this is the coarse one.
            Slider(
                value: bind(settings.gainDB, uid: settings.deviceUID, store: store,
                            keyPath: \.gainDB),
                in: gainRange
            )
            .tint(Theme.accent)
            .frame(maxWidth: 320)
            .accessibilityLabel(Text("Gain"))
            .accessibilityValue(Text(formatDB(settings.gainDB, decimals: 1)))

            HStack(spacing: 10) {
                // The one thing a level meter cannot do is say *how much*. This
                // measures instead of reporting, so it belongs next to the
                // control it sets rather than in a menu somewhere.
                Button("Set the level for me\u{2026}", action: onCalibrate)
                    .buttonStyle(.bordered)
                    .help("Measures the room and then your voice, and proposes a gain.")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 320)

            hardwareGainNote
        }
    }

    /// Shown only for microphones that have a gain stage of their own.
    ///
    /// Deliberately a footnote rather than a second control. The user sets one
    /// number and the app decides how much of it the microphone contributes; a
    /// second slider would make an implementation detail the user's problem. The
    /// switch is here because writing gain into a device is a side effect that
    /// outlives the app and is visible to other software, so refusing it has to
    /// be possible — but it is a preference, not part of the daily control.
    @ViewBuilder
    private var hardwareGainNote: some View {
        if let range = store.hardwareGainRanges[settings.deviceUID] {
            let binding = bind(settings.hardwareGainEnabled, uid: settings.deviceUID,
                               store: store, keyPath: \.hardwareGainEnabled)
            let explanation =
                "This microphone can amplify before its own converter, which is "
                + "slightly quieter than amplifying afterwards. It offers "
                + formatDB(range.minDB, decimals: 0) + " to "
                + formatDB(range.maxDB, decimals: 0)
                + ". Turn this off to leave the device's own setting alone; "
                + "the level you set stays the same either way."

            Toggle(isOn: binding) {
                Text("Use the microphone's own gain")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help(explanation)
        }
    }
}

// MARK: - PadRow

private struct PadRow: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(text: "Pad", location: .software)

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
                RowLabel(text: "HPF", location: .software)

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

// MARK: - Body-switch note

/// A caution that the microphone may be applying its own pad or filter on top of
/// ours.
///
/// The height is reserved whether or not there is anything to say. Everything
/// else in this card is laid out the same way, and a note that appeared and
/// disappeared would shove the four effect buttons up and down each time the pad
/// was switched — the exact jitter this pane was rebuilt to remove.
private struct BodySwitchNote: View {
    let settings: ChannelSettings
    /// What the microphone says about its own switches, or `nil` when it has no
    /// control channel or has not answered yet. The two cases read very
    /// differently to the user — a hedge versus a statement — and that
    /// distinction is the point of passing it at all.
    let reported: MicBodySwitches?

    var body: some View {
        Text(note ?? " ")
            .font(Theme.captionFont)
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 14)
            .opacity(note == nil ? 0 : 1)
            .accessibilityHidden(note == nil)
    }

    private var note: String? {
        ChannelProcessingMap.bodySwitchNote(
            padEnabled: settings.padEnabled,
            highPassActive: settings.hpfMode != .off,
            reported: reported)
    }
}

// MARK: - MicDetailView

/// One microphone's settings, presented as a sheet over the mixer.
///
/// Sized rather than flexible. A sheet that resizes with its content makes the
/// window jump every time a section appears, and there is no width at which
/// these controls read better — a slider row wider than about 500 points puts
/// its label and its value at opposite ends of the screen.
struct MicDetailView: View {
    let settings: ChannelSettings
    let connection: ChannelConnectionSource
    @ObservedObject var meterSource: ChannelMeterSource
    @ObservedObject var store: ParameterStore
    let onClose: () -> Void

    @State private var selectedEffect: EffectKind?
    @State private var calibration: GainCalibrationSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CardSection {
                        LiveInputMeterRow(source: meterSource)
                    }

                    CardSection {
                        VStack(spacing: 10) {
                            GainBlock(settings: settings, store: store) {
                                calibration = GainCalibrationSession(
                                    deviceUID: settings.deviceUID, store: store)
                            }
                            Divider().background(Theme.border)
                            PadRow(settings: settings, store: store)
                            Divider().background(Theme.border)
                            HPFRow(settings: settings, store: store)
                            BodySwitchNote(
                                settings: settings,
                                reported: store.bodySwitches[settings.deviceUID])
                        }
                    }

                    EffectSection(
                        settings: settings,
                        meterSource: meterSource,
                        store: store,
                        selected: $selectedEffect
                    )
                }
                .padding(14)
            }
        }
        // Fixed, not content-driven, so nothing resizes as you click around. The
        // effect parameters live in popovers, so they cannot change it either.
        //
        // The height is measured against the real bottom of the content, which
        // is not what it was before: 540 cut the lower half off the effect
        // buttons, and did so even with the frequency row hidden. The row that
        // was thought to be conditional is always laid out — it dims instead of
        // disappearing — so there was no shorter case to size against, and the
        // clipping was there from the start rather than being introduced by the
        // muted notice underneath it.
        .frame(width: 520, height: 620)
        .background(Theme.bg)
        .sheet(item: $calibration) { session in
            GainCalibrationView(session: session, settings: settings) {
                calibration = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ConnectionIcon(source: connection, activeColour: Theme.accent, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.deviceName)
                    .font(Theme.titleFont)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                ConnectionLabel(source: connection)
            }
            Spacer(minLength: 12)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Theme.panel)
    }
}
