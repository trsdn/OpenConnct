import SwiftUI

// MARK: - HeaderBar
//
// The full-width bar across the top of the window.
//
// It exists because the summed output level is the one reading that is true for
// the whole application rather than for one microphone, and it was previously
// living in the mixer column as a vertical bar beside the strips. That was the
// wrong home twice over: it competed with the strips for width in the one place
// where width is scarce, and it implied — by sitting among them — that it was
// another channel.
//
// Up here it spans the window, it cannot be scrolled away, and it costs the
// strips nothing. The horizontal shape also has room for the dB figure, the
// scale and the plain-language verdict side by side, which the 52pt column did
// not.
//
// The bar carries the three things that belong to the app as a whole: is it
// working, what is going out, and the two ways in.

struct HeaderBar: View {
    @ObservedObject var store: ParameterStore
    @ObservedObject var diagnosticsSource: DiagnosticsSource
    @ObservedObject var masterSource: ChannelMeterSource

    @State private var showDetails = false
    @State private var showDevices = false

    private var diagnostics: EngineDiagnostics { diagnosticsSource.value }

    var body: some View {
        HStack(spacing: 16) {
            statusView
            MasterMeterBar(source: masterSource)
            actions
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Theme.panel)
        .sheet(isPresented: $showDevices) {
            DeviceSelectionView(store: store)
        }
    }

    // MARK: Status
    //
    // Two audiences, two levels. Day to day the user only needs to know whether
    // the thing is working, so this shows one plain-language status and nothing
    // else. The counters behind it (dropouts, drift in ppm) are engineering
    // telemetry: useful when diagnosing a fault, meaningless otherwise, and
    // actively harmful in the default view because they change several times a
    // second and shift the layout around them.

    private enum Status {
        case ready, noDriver, stopped, glitching

        var text: String {
            switch self {
            case .ready:     return "Ready"
            case .noDriver:  return "No device"
            case .stopped:   return "Stopped"
            case .glitching: return "Dropouts"
            }
        }

        var colour: Color {
            switch self {
            case .ready: return Theme.meterGreen
            case .noDriver, .glitching: return Theme.meterAmber
            case .stopped: return Theme.meterRed
            }
        }
    }

    private var status: Status {
        if !diagnostics.running { return .stopped }
        if !diagnostics.sinkAvailable { return .noDriver }
        // Recent, not ever. Binding and priming the microphones costs a handful
        // of dropouts on every launch; testing the lifetime total lights this
        // warning at startup and never clears it.
        if diagnostics.hasRecentDropout { return .glitching }
        return .ready
    }

    private var statusView: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.colour)
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(Theme.labelFont)
                .foregroundColor(status == .ready ? Theme.textSecondary : status.colour)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 6) {
            headerButton(
                systemImage: "mic.badge.plus",
                help: "Choose microphones"
            ) { showDevices = true }

            headerButton(
                systemImage: "waveform.badge.magnifyingglass",
                help: "Technical details"
            ) { showDetails.toggle() }
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                DiagnosticsDetail(diagnostics: diagnostics)
            }
        }
    }

    @ViewBuilder
    private func headerButton(
        systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium)
                        .fill(Theme.raised)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - MasterMeterBar

/// The summed output level, horizontally, at the top of the window.
///
/// The channel meters answer "is this microphone set right?". This one answers
/// "is what leaves the app set right?" — the question the person at the other
/// end of the call cares about, and the one no channel meter can answer once
/// there is more than one microphone open.
struct MasterMeterBar: View {
    @ObservedObject var source: ChannelMeterSource

    var body: some View {
        let verdict = meterVerdict(peakDB: source.meters.postFaderPeakDB)

        HStack(spacing: 10) {
            Text("MASTER")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)

            LiveLevelMeter(
                source: source, tap: .postFader, orientation: .horizontal,
                showsScale: true)
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            // No decibel figure here, deliberately. It was the first thing the
            // eye landed on when the window opened, it changed several times a
            // second, and it answered a question nobody asks: "-14" is only
            // meaningful to someone who already knows where it ought to be.
            // The bar shows position against the target band and the word says
            // what to do about it — the number sat between them adding motion
            // and no information.
            Text(verdict.text)
                .font(Theme.captionFont)
                .foregroundColor(verdictColour(verdict))
                .lineLimit(1)
                // Fixed: the word changes while speaking and anything that
                // reflows the row would make the bar beside it twitch.
                .frame(width: 52, alignment: .leading)
        }
        .help("The level OpenConnct sends to Teams, Zoom or OBS. The lighter "
              + "section of the track is the target: the loudest parts of your "
              + "speech should land there.")
    }
}

// MARK: - DiagnosticsDetail

struct DiagnosticsDetail: View {
    let diagnostics: EngineDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(Theme.titleFont)
                .foregroundColor(Theme.textPrimary)

            row("Dropouts",
                value: "\(diagnostics.underruns + diagnostics.overruns)",
                help: "How often audio arrived too late or too early, counted "
                    + "since launch. A handful while the microphones connect is "
                    + "normal; after that the number should stop moving. If it "
                    + "keeps climbing while you speak, something is wrong.")

            row("Discarded changes",
                value: "\(diagnostics.droppedParameters)",
                help: "Settings the audio thread could not accept in time. "
                    + "Should stay at 0.")

            if !diagnostics.perChannelRatioPPM.isEmpty {
                Divider().background(Theme.border)
                Text("Clock correction per microphone")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Text("Every USB microphone runs on its own crystal, marginally "
                     + "off 48 kHz. This is how hard OpenConnct stretches that "
                     + "microphone to keep it in step, in parts per million. "
                     + "Under 100 is normal once it has settled. Right after "
                     + "plugging in, the figure swings for up to a minute; that "
                     + "is intended.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(diagnostics.perChannelRatioPPM.sorted(by: { $0.key < $1.key }), id: \.key) { uid, ppm in
                    HStack(spacing: 8) {
                        Text(diagnostics.perChannelName[uid] ?? uid)
                            .font(Theme.labelFont)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(String(format: "%+.0f ppm", ppm))
                            .font(Theme.valueFont)
                            .monospacedDigit()
                            .foregroundColor(abs(ppm) > 100 ? Theme.meterAmber : Theme.textPrimary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(Theme.valueFont)
                    .monospacedDigit()
                    .foregroundColor(value == "0" ? Theme.textPrimary : Theme.meterAmber)
                    .frame(width: 74, alignment: .trailing)
            }
            Text(help)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
