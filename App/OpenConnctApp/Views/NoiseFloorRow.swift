import SwiftUI

// MARK: - Measuring the room, inside the gate's own panel
//
// Inline rather than a sheet. The gate parameters already live in a popover,
// and a sheet raised from a popover on macOS attaches to the popover's own
// window, which then closes underneath it. More to the point, the measurement
// is one countdown and one sentence — small enough that putting it beside the
// threshold slider it sets is clearer than sending the user somewhere else and
// bringing them back.

/// Every sentence the user reads about a noise floor, in one place.
enum NoiseFloorWording {
    static let invitation = "Sets the threshold from how quiet your room actually is."

    static let instruction = "Stay quiet."

    static func headline(_ result: NoiseFloorResult) -> String {
        switch result.outcome {
        case let .propose(thresholdDB):
            return "Threshold " + formatDB(thresholdDB, decimals: 1) + "."
        case .roomTooLoud:
            return "This room is too loud to gate."
        case .aboveRange:
            return "This room is too loud to gate."
        case .nothingMeasured:
            return "Nothing reached the gate."
        }
    }

    static func detail(_ result: NoiseFloorResult) -> String {
        let floor = formatDB(result.floorDB, decimals: 1)
        switch result.outcome {
        case .propose:
            return "Your room measures \(floor) at the gate's input, and the threshold sits "
                + "\(Int(NoiseFloorCalibration.marginDB)) dB above it so an air vent or a "
                + "passing chair cannot open the gate on its own."
        case .roomTooLoud, .aboveRange:
            return "Your room measures \(floor), which is close enough to speech that any "
                + "threshold would cut the quiet ends of words. Moving the microphone "
                + "closer, or lowering the gain, will do more here than this setting can."
        case .nothingMeasured:
            return "The channel produced no signal at all. Check that the microphone is "
                + "the one you think it is and that its gain is up."
        }
    }

    /// In Core, with the arithmetic it depends on. See
    /// `NoiseFloorCalibration.changeDescription`.
    static func change(_ result: NoiseFloorResult) -> String? {
        NoiseFloorCalibration.changeDescription(result)
    }
}

struct NoiseFloorRow: View {
    let settings: ChannelSettings
    @ObservedObject var store: ParameterStore

    @State private var session: NoiseFloorSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session {
                // Handed to a child that observes it. Holding an observable
                // object in `@State` keeps it alive but does NOT subscribe to
                // it, so this view would never redraw: the measurement ran
                // correctly and the panel sat frozen on its first frame.
                ActiveMeasurement(session: session,
                                  settings: settings,
                                  dismiss: { self.session = nil })
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            // The popover can be dismissed mid-measurement by clicking away.
            // Without this the probe stays armed, which costs a per-sample
            // detector on a channel nobody is measuring.
            session?.cancel()
            session = nil
        }
    }

    private var idle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Measure the room…") {
                let s = NoiseFloorSession(deviceUID: settings.deviceUID, store: store)
                session = s
                s.start()
            }
            .buttonStyle(.bordered)
            .help(NoiseFloorWording.invitation)

            Text(NoiseFloorWording.invitation)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ActiveMeasurement: View {
    @ObservedObject var session: NoiseFloorSession
    let settings: ChannelSettings
    let dismiss: () -> Void

    var body: some View {
        switch session.phase {
        case .settling, .measuring:
            measuring
        case .finished:
            finished
        case let .failed(message):
            failed(message)
        }
    }

    private var measuring: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(NoiseFloorWording.instruction)
                .font(Theme.labelFont)
                .foregroundColor(Theme.textPrimary)
            Text("\(session.secondsLeft)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.accent)
            // Evidence that something is being heard. Without it the user is
            // staring at a number counting down and has no way to tell a quiet
            // room from a dead microphone.
            Text(formatDB(session.liveLevelDB, decimals: 0))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            Button("Cancel") {
                session.cancel()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var finished: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = session.result {
                Text(NoiseFloorWording.headline(result))
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(NoiseFloorWording.detail(result))
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let change = NoiseFloorWording.change(result) {
                    Text(change)
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Close", action: dismiss).buttonStyle(.bordered)
                    applyButton(result)
                }
            }
        }
    }

    @ViewBuilder
    private func applyButton(_ result: NoiseFloorResult) -> some View {
        if case let .propose(thresholdDB) = result.outcome {
            Button(settings.gateEnabled
                   ? "Use " + formatDB(thresholdDB, decimals: 1)
                   : "Use it and switch on") {
                session.applyAndEnable()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(Theme.captionFont)
                .foregroundColor(Theme.meterAmber)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: dismiss).buttonStyle(.bordered)
            }
        }
    }
}
