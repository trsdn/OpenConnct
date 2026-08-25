import SwiftUI

// MARK: - Guided gain calibration, the sheet
//
// Three screens in one fixed frame: a silence window, the sentence, and the
// verdict. Fixed size on purpose — a panel that resizes between its phases
// moves the buttons out from under the pointer, and this one has a button that
// ends the measurement.

struct GainCalibrationView: View {
    @ObservedObject var session: GainCalibrationSession
    let settings: ChannelSettings
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)

            VStack(alignment: .leading, spacing: 14) {
                switch session.phase {
                case .settling, .silence, .speech:
                    measuring
                case .finished:
                    finished
                case let .failed(message):
                    Text(message)
                        .font(Theme.labelFont)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
        }
        .frame(width: 420, height: 330)
        .background(Theme.bg)
        .onAppear { session.start() }
        .onDisappear { session.cancel() }
    }

    private var header: some View {
        HStack {
            Text("Set the level")
                .font(Theme.titleFont)
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.panel)
    }

    // MARK: - While measuring

    @ViewBuilder
    private var measuring: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.phase {
            case .speech:
                Text("Say this at your normal speaking volume:")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                Text(GainCalibrationSession.sentence)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("Stay quiet for a moment.")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("First the room is measured, so the app knows how much of what it hears is you.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CalibrationLevelBar(levelDB: session.liveLevelDB)

            Text(session.secondsLeft == 1 ? "1 second left" : "\(session.secondsLeft) seconds left")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: - The verdict

    @ViewBuilder
    private var finished: some View {
        if let result = session.result {
            VStack(alignment: .leading, spacing: 10) {
                Text(GainCalibrationWording.headline(result))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(GainCalibrationWording.detail(result))
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if result.noisy {
                    Text(GainCalibrationWording.noiseNote(result))
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.meterAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let note = GainCalibrationWording.faderNote(faderDB: settings.faderDB) {
                    Text(note)
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch session.phase {
            case .settling, .silence:
                Button("Cancel", action: onClose).buttonStyle(.bordered)
            case .speech:
                Button("Cancel", action: onClose).buttonStyle(.bordered)
                // The sentence takes about three seconds and the window allows
                // five; without this the user reads it and then waits, which
                // measures two seconds of them waiting.
                Button("Done speaking") { session.finishEarly() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            case .finished, .failed:
                Button("Close", action: onClose).buttonStyle(.bordered)
                applyButton
            }
        }
    }

    @ViewBuilder
    private var applyButton: some View {
        if let result = session.result {
            switch result.outcome {
            case let .adjust(newGainDB, _):
                Button("Set gain to " + formatDB(newGainDB, decimals: 1)) {
                    session.apply()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            case let .notEnoughGain(bestGainDB, _):
                Button("Use " + formatDB(bestGainDB, decimals: 1) + " anyway") {
                    session.applyBestEffort()
                    onClose()
                }
                .buttonStyle(.bordered)
            case .alreadyGood, .tooLoud, .nothingHeard:
                EmptyView()
            }
        }
    }
}

// MARK: - Live bar
//
// Deliberately plain. It exists so the user can see that something is being
// heard; it is not a meter to set a level by, and dressing it up as one would
// invite exactly the read-the-meter-while-you-speak problem this whole feature
// exists to avoid.

private struct CalibrationLevelBar: View {
    let levelDB: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(meterPosition(levelDB))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.meterTrack)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.meterGreen)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Wording
//
// Separated from the view so the sentences can be read in one place and tested.
// Every one of them states the measurement it is based on: an instruction with
// no number behind it is indistinguishable from a guess.

enum GainCalibrationWording {

    static func headline(_ r: GainCalibrationResult) -> String {
        switch r.outcome {
        case .adjust:
            return "Your level is too "
                + (r.speechPeakDB < meterTargetLowDB ? "quiet" : "loud") + "."
        case .alreadyGood:
            return "That is set well."
        case .tooLoud(atTheMicrophone: true):
            return "The microphone itself is overloading."
        case .tooLoud(atTheMicrophone: false):
            return "Too loud, and the gain is already at its lowest."
        case .notEnoughGain:
            return "Even the highest gain is not enough."
        case .nothingHeard:
            // Deliberately not "nothing was heard". The measurement cannot tell
            // silence apart from a room as loud as the talker, and both have the
            // same remedy, so it says the thing it actually established.
            return "Your voice did not stand out from the room."
        }
    }

    static func detail(_ r: GainCalibrationResult) -> String {
        let peak = formatDB(r.speechPeakDB, decimals: 1)
        switch r.outcome {
        case let .adjust(newGainDB, resultingPeakDB):
            return "Your voice peaks at \(peak). Setting the gain to "
                + formatDB(newGainDB, decimals: 1) + " puts it at "
                + formatDB(resultingPeakDB, decimals: 1)
                + ", in the middle of the range this meter aims for."
        case .alreadyGood:
            return "Your voice peaks at \(peak), inside the range this meter aims for. "
                + "There is nothing to change."
        case .tooLoud(atTheMicrophone: true):
            return "The signal arriving from the microphone is already at full scale, so its "
                + "peaks were flattened before the app saw them. No gain setting here can undo "
                + "that. Turn the microphone's own dial down, or switch on its pad."
        case .tooLoud(atTheMicrophone: false):
            return "Your voice peaks at \(peak) with the gain already as low as it goes. "
                + "Switch on the Pad, or turn the microphone's own dial down."
        case let .notEnoughGain(bestGainDB, resultingPeakDB):
            return "Your voice peaks at \(peak). At the highest gain available, "
                + formatDB(bestGainDB, decimals: 1) + ", it still only reaches "
                + formatDB(resultingPeakDB, decimals: 1)
                + ". Move closer to the microphone, or turn up its own dial."
        case .nothingHeard:
            return "Either nothing was said, or the room is as loud as you are. Check that "
                + "this is the microphone in front of you, move closer to it, and try again."
        }
    }

    /// Shown when the room is loud relative to the voice. Advisory: the gain
    /// answer above is still correct.
    static func noiseNote(_ r: GainCalibrationResult) -> String {
        "Your room is loud: the voice is only "
            + String(format: "%.0f", r.signalToNoiseDB)
            + " dB above it. Gain lifts both together, so no setting will improve that."
    }

    /// The figures above are before the fader; the strip meter is after it. When
    /// the two differ enough to notice, say so — otherwise a user calibrates,
    /// sees the strip meter unchanged, and concludes the feature is broken.
    ///
    /// Stated as a fact, not as a problem. Where someone sets their faders is
    /// their business.
    static func faderNote(faderDB: Float) -> String? {
        guard abs(faderDB) > 3 else { return nil }
        return "This channel's fader is at " + formatDB(faderDB, decimals: 1)
            + ", so its strip meter reads that much lower than the figures above."
    }
}
